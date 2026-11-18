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
    /// order and after a relaunch, and an older one must never be applied again.
    private static let lastAppliedKey = "perch.sync.lastAppliedAt"
    private var lastAppliedAt: Date {
        get { UserDefaults.standard.object(forKey: Self.lastAppliedKey) as? Date ?? .distantPast }
        set { UserDefaults.standard.set(newValue, forKey: Self.lastAppliedKey) }
    }

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
        guard let data = dict[SyncPayload.key] as? Data, let p = try? SyncPayload.decode(data) else { return }
        lastPayloadBytes = data.count
        apply(p)
    }

    private func apply(_ p: SyncPayload) {
        // Ignore stale payloads (queued deliveries can arrive out of order).
        guard p.sentAt >= lastAppliedAt else { return }
        lastAppliedAt = p.sentAt
        lastReceived = Date()
        status = .received(Date(), p.command)
        Task {
            if p.command == .logout {
                await AppModel.shared.logout(propagate: false)
                return
            }
            await p.apply(to: AppModel.shared.store)
            // An `accounts` list that arrives empty means the iPhone logged out.
            if await AppModel.shared.store.credentials == nil {
                await AppModel.shared.logout(propagate: false)
                return
            }
            // The iPhone sends its ~35 KB endpoint config only when it changed: a Watch
            // that missed it (fresh install, lost context) asks for it once.
            if let theirs = p.configUpdatedAt, p.config == nil,
               theirs != (await AppModel.shared.store.config.updatedAt) {
                request(wantConfig: true)
            }
            // No haptic: syncing must stay silent.
        }
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
