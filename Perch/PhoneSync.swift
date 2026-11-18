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

    var statusText: String {
        switch status {
        case .idle: return "Not synced yet"
        case .unavailable(let why): return why
        case .sent(let d): return "Sent to Watch \(RelativeTime.short(d)) ago"
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
    /// The Watch asked for the full endpoint config (it has none or a different version).
    private var pendingWantConfig = false
    /// Config version last delivered, so the ~35 KB config is sent only when it changed.
    private var lastSentConfigUpdatedAt: String?

    func start() {
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
            self.send(p)
        }
    }

    /// "Sync to Watch now" and the Watch's request.
    func syncNow() { scheduleSend() }

    func sendLogout() {
        pendingSend?.cancel()      // a queued update must never land after the logout
        pendingSend = nil
        send(SyncPayload(command: .logout))
    }

    private func payload() async -> SyncPayload {
        let store = AppModel.shared.store
        let accounts = await store.accounts
        if accounts.isEmpty { return SyncPayload(command: .logout) }
        let cfg = await store.config
        let includeConfig = pendingWantConfig || cfg.updatedAt != lastSentConfigUpdatedAt
        return SyncPayload(command: .update, credentials: await store.credentials, accounts: accounts,
                           config: includeConfig ? cfg : nil, material: await store.material,
                           remoteOverrideURL: await store.remoteOverrideURL?.absoluteString,
                           remoteOverrideIsAuthoritative: true,
                           activeAccountId: await store.activeAccountId,
                           configUpdatedAt: cfg.updatedAt)
    }

    private func send(_ p: SyncPayload) {
        guard let session, session.activationState == .activated else {
            status = .unavailable("Watch session not active"); return
        }
        guard session.isPaired else { status = .unavailable("No paired Apple Watch"); return }
        guard session.isWatchAppInstalled else { status = .unavailable("Perch isn't installed on the Watch"); return }
        let dict = p.dictionary()
        // Never send an empty context: it would replace the Watch's copy of the state.
        guard dict[SyncPayload.key] != nil else { status = .failed("Couldn't encode the session"); return }
        do {
            try session.updateApplicationContext(dict)
            lastSent = Date()
            status = .sent(Date())
            messageError = nil
            if p.config != nil {
                lastSentConfigUpdatedAt = p.configUpdatedAt
                pendingWantConfig = false
            }
        } catch {
            status = .failed("Context error: \(error.localizedDescription)")
        }
        if session.isReachable {        // the Watch app is running: apply it now
            session.sendMessage(dict, replyHandler: nil) { [weak self] error in
                Task { @MainActor in self?.messageError = error.localizedDescription }
            }
        }
    }

    fileprivate func handleIncoming(_ message: [String: Any]) {
        if message["request"] as? String == "sync" {
            if message["wantConfig"] as? Bool == true { pendingWantConfig = true }
            syncNow()
        } else if let p = SyncPayload.from(dictionary: message), p.command == .logout {
            // Logging out on the Watch logs out the iPhone too (the store wipe then sends
            // one .logout back, which the Watch ignores: it is already logged out).
            Task { await AppModel.shared.logout(propagate: false) }
        }
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
