import Foundation
import WatchConnectivity
import XKit

/// Outcome of the last sync, written in one place each; the status line is derived from
/// it, so it reports what happened rather than what was attempted.
enum SyncStatus: Equatable {
    case idle
    case unavailable(String)
    case sent(Date)
    case failed(String)
}

/// iPhone side of WatchConnectivity: pushes accounts, endpoint config and transaction
/// material to the Watch, and answers the Watch's sync requests.
///
/// Sending is driven by the session store: whenever what the Watch receives changes
/// (accounts, active account, config version, signing material, override URL), one
/// coalesced send goes out. Nothing has to remember to call `syncNow()` after a change.
///
/// Channels, per Apple's WatchConnectivity docs: `updateApplicationContext` is the
/// state channel (latest wins, delivered when the Watch wakes, works while it is not
/// reachable); `sendMessage` is only a fast path while the Watch app is running.
/// `transferUserInfo` queues *every* dictionary, so it is not used for state.
@MainActor
final class PhoneSync: NSObject, ObservableObject, SyncChannel {
    static let shared = PhoneSync()

    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var lastSent: Date?
    /// Last fast-path delivery error (the context write may still have succeeded).
    @Published private(set) var messageError: String?

    /// The last payload the Watch said it applied. Without this the phone can only
    /// report what it *sent*, which is how a permanently stale Watch went unnoticed.
    @Published private(set) var lastAckSeq: UInt64 = 0
    @Published private(set) var lastAckAt: Date?

    var messageErrorText: String? {
        guard let messageError else { return nil }
        if messageError.lowercased().contains("not reachable") {
            return "Watch app closed — the state is queued"
        }
        return messageError
    }

    var statusText: String {
        switch status {
        case .idle: return "Not synced yet"
        case .unavailable(let why): return why
        case .sent(let d):
            if lastAckSeq > 0, lastAckSeq >= lastSentSeq, let at = lastAckAt {
                return "Watch confirmed \(RelativeTime.short(at)) ago"
            }
            return "Sent to Watch \(RelativeTime.short(d)) ago"
        case .failed(let why): return why
        }
    }

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    /// Everything the payload depends on, as one comparable value.
    private struct Fingerprint: Equatable {
        var accounts: [XAccount]
        var activeAccountId: String?
        var configUpdatedAt: String
        var materialAt: Date?
        var override: String?
    }

    private var lastFingerprint: Fingerprint?
    private var pendingSend: Task<Void, Never>?
    /// `start()` runs from `onAppear`: it must make exactly one observer, or every extra
    /// call duplicates every send.
    private var started = false
    /// Monotonic send counter (persisted): the Watch applies only newer payloads, so a
    /// stale re-delivered context (e.g. the pre-logout state) can never be applied again.
    private static let seqKey = "perch.sync.seq"
    private var seq: UInt64 {
        get { UInt64(UserDefaults.standard.string(forKey: Self.seqKey) ?? "") ?? 0 }
        set { UserDefaults.standard.set(String(newValue), forKey: Self.seqKey) }
    }
    private func nextSeq() -> UInt64 { let n = seq + 1; seq = n; return n }

    /// Identifies this installation. The Watch compares `(origin, seq)` pairs, so a
    /// reinstalled iPhone (whose counter restarts at 1) is applied instead of being
    /// silently dropped forever by a Watch holding a higher counter.
    private static let originKey = "perch.sync.origin"
    private var origin: String {
        if let s = UserDefaults.standard.string(forKey: Self.originKey), !s.isEmpty { return s }
        let s = UUID().uuidString
        UserDefaults.standard.set(s, forKey: Self.originKey)
        return s
    }

    /// The Watch asked for the full endpoint config (it has none or a different version).
    private var pendingWantConfig = false
    /// `Reset sync`: apply regardless of seq on the Watch, send the full config again.
    private var pendingReset = false
    /// Config version last delivered, so the ~35 KB config is sent only when it changed.
    /// Persisted: in memory it made every phone launch re-send the whole config.
    private static let configSentKey = "perch.sync.configSent"
    private var lastSentConfigUpdatedAt: String? {
        get { UserDefaults.standard.string(forKey: Self.configSentKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.configSentKey) }
    }

    private var lastSentSeq: UInt64 = 0
    private var resendAttempts = 0
    private var lastResendAt = Date.distantPast

    func start() {
        guard !started else { return }
        started = true
        guard let session else { status = .unavailable("WatchConnectivity unsupported"); return }
        session.delegate = self
        session.activate()
        AppModel.shared.sync = self
        let store = AppModel.shared.store
        Task { [weak self] in
            await store.observe { [weak self] in
                Task { @MainActor in self?.storeChanged() }
            }
        }
    }

    private func storeChanged() {
        Task { [weak self] in
            guard let self else { return }
            let fp = await self.fingerprint()
            guard fp != self.lastFingerprint else { return }
            self.lastFingerprint = fp
            self.scheduleSend()
        }
    }

    /// A failed context write must not be remembered as delivered: clear the fingerprint
    /// (the next store event retries) and try once more shortly, while the Watch is there.
    private func retrySoon() {
        lastFingerprint = nil
        guard AppModel.shared.isLoggedIn else { return }
        pendingSend?.cancel()
        pendingSend = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard let s = self.session, s.isWatchAppInstalled else { return }
            self.scheduleSend()
        }
    }

    private func fingerprint() async -> Fingerprint {
        let store = AppModel.shared.store
        return Fingerprint(accounts: await store.accounts,
                           activeAccountId: await store.activeAccountId,
                           configUpdatedAt: await store.config.updatedAt,
                           materialAt: await store.material?.fetchedAt,
                           override: await store.remoteOverrideURL?.absoluteString)
    }

    /// A login writes accounts, then the profile, then the signing material within
    /// moments: send the newest state once. The window is a coalescing interval, not a
    /// wait for some other work to finish.
    private func scheduleSend() {
        pendingSend?.cancel()
        pendingSend = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let self else { return }
            let p = await self.payload()
            guard !Task.isCancelled else { return }
            if !self.send(p) { self.retrySoon() }
        }
    }

    /// "Sync to Watch now" and the Watch's request.
    func syncNow() { scheduleSend() }

    /// The repair path: forget what we believe the Watch has, resend everything
    /// (accounts, config, material) and tell it to drop its applied floor.
    func resetSync() {
        lastAckSeq = 0
        lastAckAt = nil
        resendAttempts = 0
        lastSentConfigUpdatedAt = nil
        pendingWantConfig = true
        pendingReset = true
        lastFingerprint = nil
        scheduleSend()
    }

    func sendLogout() {
        pendingSend?.cancel()      // a queued update must never land after the logout
        pendingSend = nil
        if !send(SyncPayload(command: .logout, seq: nextSeq(), origin: origin)) { retrySoon() }
    }

    private func payload() async -> SyncPayload {
        let store = AppModel.shared.store
        let accounts = await store.accounts
        let seq = nextSeq()
        let o = origin
        let reset: Bool? = pendingReset ? true : nil
        if accounts.isEmpty {
            return SyncPayload(command: .logout, seq: seq, origin: o, reset: reset)
        }
        let cfg = await store.config
        let includeConfig = pendingWantConfig || pendingReset || cfg.updatedAt != lastSentConfigUpdatedAt
        return SyncPayload(command: .update, credentials: await store.credentials, accounts: accounts,
                           config: includeConfig ? cfg : nil, material: await store.material,
                           remoteOverrideURL: await store.remoteOverrideURL?.absoluteString,
                           remoteOverrideIsAuthoritative: true,
                           activeAccountId: await store.activeAccountId,
                           configUpdatedAt: cfg.updatedAt, seq: seq, origin: o, reset: reset)
    }

    @discardableResult
    private func send(_ p: SyncPayload) -> Bool {
        guard let session, session.activationState == .activated else {
            status = .unavailable("Watch session not active"); return false
        }
        guard session.isPaired else { status = .unavailable("No paired Apple Watch"); return false }
        guard session.isWatchAppInstalled else { status = .unavailable("Perch isn't installed on the Watch"); return false }
        let dict = p.dictionary()
        // Never send an empty context: it would replace the Watch's copy of the state.
        guard dict[SyncPayload.key] != nil else { status = .failed("Couldn't encode the session"); return false }
        var ok = true
        do {
            try session.updateApplicationContext(dict)
            lastSent = Date()
            lastSentSeq = p.seq ?? lastSentSeq
            status = .sent(Date())
            messageError = nil
            if p.config != nil {
                lastSentConfigUpdatedAt = p.configUpdatedAt
                pendingWantConfig = false
            }
            if p.reset == true { pendingReset = false }
        } catch {
            status = .failed("Context error: \(error.localizedDescription)")
            ok = false
        }
        if session.isReachable {        // the Watch app is running: apply it now
            session.sendMessage(dict, replyHandler: nil) { [weak self] error in
                Task { @MainActor in self?.messageError = error.localizedDescription }
            }
        }
        return ok
    }

    fileprivate func handleIncoming(_ message: [String: Any]) {
        if let ack = message["ack"] as? String, let applied = Self.parseIdentity(ack) {
            lastAckSeq = applied.seq
            lastAckAt = Date()
            // A daemon that stops sending once an ack mismatch is possible would be
            // stuck; retry, but bounded, so a broken Watch cannot spin the phone.
            if applied.seq < lastSentSeq, resendAttempts < 3,
               Date().timeIntervalSince(lastResendAt) > 10 {
                resendAttempts += 1
                lastResendAt = Date()
                scheduleSend()
            }
            return
        }
        if message["request"] as? String == "sync" {
            if message["wantConfig"] as? Bool == true { pendingWantConfig = true }
            // The Watch tells us what it already has; resend when we are ahead.
            if let raw = message["applied"] as? String, let applied = Self.parseIdentity(raw),
               applied.seq < lastSentSeq {
                scheduleSend()
            } else {
                syncNow()
            }
        } else if let p = SyncPayload.from(dictionary: message), p.command == .logout {
            // A queued logout from an earlier session must not wipe a newer login.
            if let lastSent, p.sentAt < lastSent { return }
            // Logging out on the Watch logs out the iPhone too (the store wipe then sends
            // one .logout back, which the Watch ignores: it is already logged out).
            Task { await AppModel.shared.logout(propagate: false) }
        }
    }

    /// "origin:seq" for both the Watch's ack and its sync request.
    private static func parseIdentity(_ raw: String) -> (origin: String, seq: UInt64)? {
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let seq = UInt64(parts[1]), seq > 0 else { return nil }
        return (String(parts[0]), seq)
    }
}

extension PhoneSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if activationState == .activated {
                if AppModel.shared.isLoggedIn { self.syncNow() }
            } else {
                self.status = .unavailable("Inactive: \(error?.localizedDescription ?? "")")
            }
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            if session.isWatchAppInstalled, AppModel.shared.isLoggedIn { self.syncNow() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let box = MessageBox(message)
        Task { @MainActor in self.handleIncoming(box.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler(["ok": true])
        let box = MessageBox(message)
        Task { @MainActor in self.handleIncoming(box.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let box = MessageBox(userInfo)
        Task { @MainActor in self.handleIncoming(box.value) }
    }
}
