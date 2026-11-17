import Foundation
import WatchConnectivity
import XKit

/// Watch side of WatchConnectivity: receives the session from the iPhone.
@MainActor
final class WatchSync: NSObject, ObservableObject, SyncChannel {
    static let shared = WatchSync()

    @Published private(set) var statusText = "Waiting for iPhone"
    @Published private(set) var lastReceived: Date?

    func start() {
        guard WCSession.isSupported() else { statusText = "Unsupported"; return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        AppModel.shared.sync = self
    }

    /// Ask the iPhone to (re)send credentials/config/material.
    func syncNow() {
        let s = WCSession.default
        guard s.activationState == .activated else { statusText = "Not activated"; return }
        if s.isReachable {
            s.sendMessage(["request": "sync"], replyHandler: { _ in }, errorHandler: { error in
                Task { @MainActor in self.statusText = "iPhone error: \(error.localizedDescription)" }
            })
            statusText = "Requested from iPhone…"
        } else {
            s.transferUserInfo(["request": "sync"])
            statusText = "iPhone not reachable — open Perch on iPhone"
        }
        // Also apply whatever context we already have.
        if let p = SyncPayload.from(dictionary: s.receivedApplicationContext) { apply(p) }
    }

    func sendLogout() {
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        let dict = SyncPayload(command: .logout).dictionary()
        if s.isReachable { s.sendMessage(dict, replyHandler: nil, errorHandler: nil) }
        s.transferUserInfo(dict)
    }

    fileprivate func receive(_ dict: [String: Any]) {
        guard let p = SyncPayload.from(dictionary: dict) else { return }
        apply(p)
    }

    private var lastAppliedAt: Date = .distantPast

    private func apply(_ p: SyncPayload) {
        // Ignore stale payloads (userInfo transfers can arrive out of order).
        guard p.sentAt >= lastAppliedAt else { return }
        lastAppliedAt = p.sentAt
        lastReceived = Date()
        statusText = p.command == .logout ? "Logged out from iPhone" : "Synced from iPhone"
        Task {
            if p.command == .logout {
                await AppModel.shared.logout(propagate: false)
            } else {
                let wasLoggedIn = AppModel.shared.isLoggedIn
                await p.apply(to: AppModel.shared.store)
                await AppModel.shared.reloadState()
                // A real login arriving from the iPhone ends demo mode (it may have been
                // switched on from onboarding before the session was synced).
                if !wasLoggedIn, AppModel.shared.isLoggedIn, AppModel.shared.demoMode {
                    AppModel.shared.demoMode = false
                }
            }
            Haptics.success()
        }
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let box = MessageBox(session.receivedApplicationContext)
        Task { @MainActor in
            self.statusText = activationState == .activated ? "Connected" : "Inactive"
            if !box.value.isEmpty { self.receive(box.value) }
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
