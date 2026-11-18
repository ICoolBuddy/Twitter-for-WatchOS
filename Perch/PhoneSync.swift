import Foundation
import WatchConnectivity
import XKit

/// iPhone side of WatchConnectivity: pushes credentials, endpoint config and
/// transaction material to the Watch, and answers the Watch's sync requests.
@MainActor
final class PhoneSync: NSObject, ObservableObject, SyncChannel {
    static let shared = PhoneSync()

    @Published private(set) var statusText = "Not started"
    @Published private(set) var lastSent: Date?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func start() {
        guard let session else { statusText = "WatchConnectivity unsupported"; return }
        session.delegate = self
        session.activate()
        AppModel.shared.sync = self
    }

    private func payload() async -> SyncPayload {
        let store = AppModel.shared.store
        let accounts = await store.accounts
        if accounts.isEmpty { return SyncPayload(command: .logout) }
        return SyncPayload(command: .update, credentials: await store.credentials, accounts: accounts,
                           config: await store.config, material: await store.material,
                           remoteOverrideURL: await store.remoteOverrideURL?.absoluteString,
                           remoteOverrideIsAuthoritative: true)
    }

    func syncNow() {
        Task { await send(await payload()) }
    }

    func sendLogout() {
        Task { await send(SyncPayload(command: .logout)) }
    }

    private func send(_ p: SyncPayload) async {
        guard let session, session.activationState == .activated else {
            statusText = "Watch session not active"
            return
        }
        guard session.isPaired else { statusText = "No paired Apple Watch"; return }
        guard session.isWatchAppInstalled else { statusText = "Perch isn't installed on the Watch"; return }
        let dict = p.dictionary()
        do {
            // Latest state survives even if the Watch app isn't running…
            try session.updateApplicationContext(dict)
        } catch {
            statusText = "Context error: \(error.localizedDescription)"
        }
        // …and a queued transfer guarantees delivery of each change.
        session.transferUserInfo(dict)
        if session.isReachable {
            session.sendMessage(dict, replyHandler: nil, errorHandler: nil)
        }
        lastSent = Date()
        statusText = p.command == .logout ? "Sent logout to Watch" : "Sent session to Watch"
    }

    fileprivate func handleIncoming(_ message: [String: Any]) {
        if message["request"] as? String == "sync" {
            syncNow()
        } else if let p = SyncPayload.from(dictionary: message), p.command == .logout {
            // Logging out on the Watch logs out the iPhone too.
            Task { await AppModel.shared.logout(propagate: false) }
        }
    }
}

extension PhoneSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            self.statusText = activationState == .activated ? "Ready" : "Inactive: \(error?.localizedDescription ?? "")"
            if activationState == .activated, AppModel.shared.isLoggedIn { self.syncNow() }
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

