import Foundation
import WatchConnectivity
import XKit

/// Watch side of WatchConnectivity: receives the session from the iPhone.
@MainActor
final class WatchSync: NSObject, ObservableObject, SyncChannel {
    static let shared = WatchSync()

    /// What the last step really did (the status line is derived from it).
    enum Status: Equatable {
        case waiting
        case unavailable(String)
        case requested(reachable: Bool)
        case received(Date, SyncPayload.Command)
        case failed(String)
    }

    @Published private(set) var status: Status = .waiting
    @Published private(set) var lastReceived: Date?
    /// Size of the last payload, for the Settings diagnostics line.
    @Published private(set) var lastPayloadBytes = 0

    var statusText: String {
        switch status {
        case .waiting: return "Waiting for iPhone"
        case .unavailable(let why): return why
        case .requested(let reachable):
            return reachable ? "Asked your iPhone…" : "iPhone not reachable — open Perch on iPhone"
        case .received(let d, let command):
            return (command == .logout ? "Logged out from iPhone " : "Synced from iPhone ")
                + RelativeTime.short(d) + " ago"
        case .failed(let why): return why
        }
    }

    /// The newest payload already applied, persisted: queued deliveries can arrive out of
    /// order and after a relaunch, and an older one must never be applied again — not even
    /// the context the phone already holds (that is how a local logout got undone).
    /// Stored as "origin:seq": `seq` is only comparable within one installation.
    private static let appliedKey = "perch.sync.applied"
    private var applied: (origin: String, seq: UInt64)? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.appliedKey) else { return nil }
            guard !raw.isEmpty else { return nil }
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let seq = UInt64(parts[1]) else { return nil }
            return (String(parts[0]), seq)
        }
        set {
            if let newValue {
                UserDefaults.standard.set("\(newValue.origin):\(newValue.seq)", forKey: Self.appliedKey)
            } else {
                // "" is an explicit "forget everything": never fall back to the legacy key.
                UserDefaults.standard.set("", forKey: Self.appliedKey)
            }
        }
    }
    /// Pre-origin builds stored a bare counter. It is never read again (a new origin is
    /// always accepted), only cleared so a downgrade cannot resurrect it.
    private static let legacySeqKey = "perch.sync.lastAppliedSeq"

    /// The highest payload *scheduled* (applied or still in flight) for the current
    /// origin. Dedupe happens here, synchronously, so a duplicate delivery cannot queue
    /// behind the same work twice.
    private var scheduled: (origin: String, seq: UInt64)?

    /// Applies run one at a time: two payloads must never interleave in the store.
    private var applyTail: Task<Void, Never>?

    /// Fallback for payloads from an older iPhone build (no `seq`).
    private static let lastAppliedKey = "perch.sync.lastAppliedAt"
    private var lastAppliedAt: Date {
        get { UserDefaults.standard.object(forKey: Self.lastAppliedKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastAppliedKey) }
    }
    /// A config version already asked for, so a payload that cannot carry it cannot
    /// re-trigger the request forever.
    private var requestedConfigVersion: String?

    func start() {
        guard WCSession.isSupported() else { status = .unavailable("Unsupported"); return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        AppModel.shared.sync = self
    }

    /// Ask the iPhone to (re)send the session.
    func syncNow() { request(wantConfig: false) }

    private func request(wantConfig: Bool) {
        let s = WCSession.default
        guard s.activationState == .activated else {
            // Activation completes shortly; `activationDidCompleteWith` asks then.
            status = .unavailable("Connecting to iPhone…")
            return
        }
        var message: [String: Any] = ["request": "sync"]
        if wantConfig { message["wantConfig"] = true }
        // Tell the iPhone what we already applied, so it can resend when it is ahead.
        if let applied { message["applied"] = "\(applied.origin):\(applied.seq)" }
        if s.isReachable {
            // A message wakes the iPhone app; the queued transfer covers "not reachable".
            s.sendMessage(message, replyHandler: { _ in }, errorHandler: { error in
                Task { @MainActor in self.status = .failed("iPhone error: \(error.localizedDescription)") }
            })
        } else {
            s.transferUserInfo(message)
        }
        status = .requested(reachable: s.isReachable)
        // Also apply whatever context we already have.
        receive(s.receivedApplicationContext)
    }

    func sendLogout() {
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        let dict = SyncPayload(command: .logout).dictionary()
        if s.isReachable { s.sendMessage(dict, replyHandler: nil, errorHandler: nil) }
        s.transferUserInfo(dict)
    }

    fileprivate func receive(_ dict: [String: Any]) {
        guard let data = dict[SyncPayload.key] as? Data else { return }
        lastPayloadBytes = data.count
        guard let p = try? SyncPayload.decode(data) else {
            status = .failed("Payload not understood")
            return
        }
        apply(p)
    }

    private func apply(_ p: SyncPayload) {
        // "Reset sync" on the iPhone: forget the applied floor and take this payload
        // whatever its seq. It is the only escape hatch when the two sides disagree.
        if p.reset == true {
            applied = nil
            scheduled = nil
            UserDefaults.standard.removeObject(forKey: Self.legacySeqKey)
        }
        let origin = p.origin ?? "legacy"
        if let seq = p.seq, seq > 0 {
            // Queued deliveries can arrive out of order and the phone re-delivers the
            // context it already has: only a strictly newer payload may proceed.
            if let s = scheduled, s.origin == origin, seq <= s.seq { return }
            if let a = applied, a.origin == origin, seq <= a.seq { return }
            scheduled = (origin, seq)
        } else {
            guard p.sentAt > lastAppliedAt else { return }
        }
        // Chain the work: two payloads must never interleave inside the store, and the
        // applied receipt is written only after the work really finished.
        let previous = applyTail
        applyTail = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.perform(p, origin: origin)
        }
    }

    private func perform(_ p: SyncPayload, origin: String) async {
        if p.command == .logout {
            await AppModel.shared.logout(propagate: false)
            commit(p, origin: origin)
            return
        }
        await p.apply(to: AppModel.shared.store)
        // An `accounts` list that arrives empty means the iPhone logged out.
        if await AppModel.shared.store.credentials == nil {
            await AppModel.shared.logout(propagate: false)
            commit(p, origin: origin)
            return
        }
        // The iPhone sends its ~35 KB endpoint config only when it changed: a Watch
        // that missed it (fresh install, lost context) asks for it once.
        if let theirs = p.configUpdatedAt, p.config == nil,
           theirs != (await AppModel.shared.store.config.updatedAt),
           theirs != requestedConfigVersion {
            requestedConfigVersion = theirs
            request(wantConfig: true)
        }
        commit(p, origin: origin)
    }

    /// Records the applied identity **after** the payload was applied, and tells the
    /// iPhone: without this receipt the phone can only say "Sent".
    private func commit(_ p: SyncPayload, origin: String) {
        if let seq = p.seq, seq > 0 {
            applied = (origin, seq)
            UserDefaults.standard.removeObject(forKey: Self.legacySeqKey)
        }
        lastAppliedAt = p.sentAt
        lastReceived = p.sentAt
        status = .received(p.sentAt, p.command)
        sendAck()
        // No haptic: syncing must stay silent.
    }

    private func sendAck() {
        guard let applied else { return }
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else { return }
        s.sendMessage(["ack": "\(applied.origin):\(applied.seq)"], replyHandler: nil, errorHandler: nil)
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let box = MessageBox(session.receivedApplicationContext)
        Task { @MainActor in
            guard activationState == .activated else {
                self.status = .unavailable("Inactive")
                return
            }
            if !box.value.isEmpty {
                self.status = .waiting
                self.receive(box.value)
            } else if await AppModel.shared.store.credentials == nil {
                // Nothing cached and not logged in: ask the iPhone once (a tap on
                // "Sync from iPhone" before activation finished was lost before).
                self.syncNow()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let box = MessageBox(applicationContext)
        Task { @MainActor in self.receive(box.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let box = MessageBox(userInfo)
        Task { @MainActor in self.receive(box.value) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let box = MessageBox(message)
        Task { @MainActor in self.receive(box.value) }
    }
}
