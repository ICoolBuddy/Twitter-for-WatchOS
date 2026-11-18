import Foundation
import SwiftUI
import XKit

/// Implemented by the platform-specific WatchConnectivity bridges.
@MainActor
protocol SyncChannel: AnyObject {
    /// iPhone: push credentials/config/material to the Watch. Watch: ask the iPhone for them.
    func syncNow()
    /// Tell the other device to log out too.
    func sendLogout()
    var statusText: String { get }
}

/// App-wide state shared by the iOS and watchOS apps.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: XSessionStore
    /// The only owner of the signing material download (client 404 retry + manual refresh).
    let materialProvider: TransactionMaterialProvider
    let posts = PostStateStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var client: XClient
    @Published private(set) var accounts: [XAccount] = []
    @Published private(set) var activeAccountId: String?
    @Published private(set) var badge = XBadgeCounts(notifications: 0, dms: 0)
    @Published private(set) var viewer: XUser?
    @Published private(set) var endpointsUpdatedAt = ""
    @Published private(set) var materialSummary = "none"
    @Published private(set) var remoteOverrideURL: URL?
    @Published private(set) var lastStateChange = Date()
    @Published var busyMessage: String?
    /// True once the first `reloadState()` has read the stored session (before
    /// that `isLoggedIn` is false even for a logged-in user).
    @Published private(set) var stateLoaded = false

    weak var sync: SyncChannel?
    /// Platform hook run on logout (the Watch clears its offline caches).
    var onLogout: (() -> Void)?
    private var lastBadgeFetch: Date = .distantPast
    /// Never poll X more often than this in the background.
    static let pollInterval: TimeInterval = 15 * 60
    #if DEBUG
    /// Set by `installDebugSession`: the screenshot harness owns the app state.
    private var hasDebugSession = false
    #endif

    private init() {
        PerchSettings.registerDefaults()
        let store = XSessionStore()
        self.store = store
        let provider = TransactionMaterialProvider(store: store)
        materialProvider = provider
        client = Self.makeClient(store: store, provider: provider)
        UserDefaults.standard.removeObject(forKey: "demoMode")  // left over from the removed demo mode
        Task { [weak self] in
            await store.observe { Task { @MainActor in await AppModel.shared.reloadState() } }
            await self?.reloadState()
        }
    }

    var canBrowse: Bool { isLoggedIn }

    var activeAccount: XAccount? { accounts.first { $0.id == activeAccountId } }

    func reloadState() async {
        #if DEBUG
        if hasDebugSession { return }
        #endif
        accounts = await store.accounts
        activeAccountId = await store.activeAccountId
        // Offline taps are queued per account: only the active one's replay.
        posts.setAccount(activeAccountId)
        let creds = await store.credentials
        let wasLoggedIn = isLoggedIn
        isLoggedIn = creds != nil
        endpointsUpdatedAt = await store.config.updatedAt
        remoteOverrideURL = await store.remoteOverrideURL
        if let m = await store.material {
            materialSummary = "\(m.source), \(RelativeTime.short(m.fetchedAt)) ago"
        } else {
            materialSummary = "none"
        }
        if viewer == nil { viewer = activeAccount?.user }
        if wasLoggedIn != isLoggedIn { rebuildClient() }
        lastStateChange = Date()
        stateLoaded = true
    }

    private static func makeClient(store: XSessionStore, provider: TransactionMaterialProvider) -> XClient {
        LiveXClient(store: store, refreshMaterial: { try await provider.material(force: true) })
    }

    private func rebuildClient() {
        client = Self.makeClient(store: store, provider: materialProvider)
        viewer = nil
    }

    // MARK: Account

    func login(_ creds: XCredentials) async {
        let id = await store.upsertAccount(creds, user: nil)
        await reloadState()
        rebuildClient()
        // Cache the profile so account pickers show a name and avatar immediately.
        if let v = try? await client.viewer() {
            viewer = v
            await store.updateUser(v, forAccount: id)
            accounts = await store.accounts
        }
        sync?.syncNow()
        // Signing material makes some endpoints (search) work; best effort.
        Task { try? await self.refreshMaterial() }
    }

    /// Switches the device-local active account. The other device keeps its own.
    func switchAccount(to id: String) async {
        // A new account always opens on For You (the default timeline).
        UserDefaults.standard.set(HomeKind.forYou.rawValue, forKey: PerchSettings.homeKind)
        guard id != activeAccountId else { return }
        await store.setActiveAccount(id)
        viewer = nil
        badge = XBadgeCounts(notifications: 0, dms: 0)
        lastBadgeFetch = .distantPast
        posts.reset()
        rebuildClient()
        await reloadState()
        await loadViewer()
    }

    func removeAccount(_ id: String, propagate: Bool = true) async {
        let wasActive = activeAccountId == id
        await store.removeAccount(id)
        clearTimelineCaches(accountID: id)
        posts.dropQueue(accountId: id)
        if wasActive {
            viewer = nil
            badge = XBadgeCounts(notifications: 0, dms: 0)
            lastBadgeFetch = .distantPast
            posts.reset()
            rebuildClient()
        }
        await reloadState()
        await loadViewer()
        if propagate { sync?.syncNow() }
    }

    func logout(propagate: Bool = true) async {
        await store.wipe()
        clearAllTimelineCaches()
        posts.reset()
        posts.clearQueue()
        onLogout?()
        badge = XBadgeCounts(notifications: 0, dms: 0)
        viewer = nil
        await reloadState()
        if propagate { sync?.sendLogout() }
    }

    func loadViewer() async {
        guard canBrowse else { viewer = nil; return }
        guard viewer == nil else { return }
        guard let v = try? await client.viewer() else { return }
        viewer = v
        if let id = activeAccountId {
            await store.updateUser(v, forAccount: id)
            accounts = await store.accounts
        }
    }

    /// Disk cache file stem for a timeline of the active account.
    func timelineCacheName(_ kind: HomeKind) -> String {
        "home-\(activeAccountId ?? "none")-\(kind.rawValue)"
    }

    // MARK: Disk cache

    private func clearAllTimelineCaches() {
        TimelineDiskCache.clear()
        // TODO(contract): `TimelineDiskCache.clear()` (watch-ui) must clear every
        // `perch-home-*` file too; AppModel removes them itself for now.
        clearTimelineFiles(prefix: "perch-home-")
    }

    private func clearTimelineCaches(accountID: String) {
        clearTimelineFiles(prefix: "perch-home-\(accountID)-")
    }

    private func clearTimelineFiles(prefix: String) {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    // MARK: Endpoints & signing

    /// Remote override first (cheap), then scraping x.com's JS bundles.
    func refreshEndpoints(scrape: Bool = true) async throws {
        busyMessage = "Refreshing endpoints…"
        defer { busyMessage = nil }
        var lastError: Error?
        if let url = await store.remoteOverrideURL {
            do {
                let cfg = try await RemoteOverride.fetch(url)
                await store.mergeConfig(cfg)
            } catch { lastError = error }
        }
        if scrape {
            do {
                let base = await store.config
                let discovery = EndpointDiscovery()      // platform caps live in XKit
                let cfg = try await discovery.discover(base: base)
                await store.setConfig(cfg)
                lastError = nil
            } catch {
                if lastError == nil { lastError = error }
            }
        }
        await reloadState()
        sync?.syncNow()
        if let lastError { throw lastError }
    }

    func refreshMaterial() async throws {
        try await materialProvider.material(force: true)
        await reloadState()
        sync?.syncNow()
    }

    func setRemoteOverride(_ s: String) async {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.setRemoteOverrideURL(trimmed.isEmpty ? nil : URL(string: trimmed))
        await reloadState()
        sync?.syncNow()
    }

    // MARK: Badge

    /// Throttled to one request per 15 minutes unless `force`.
    func refreshBadge(force: Bool = false) async {
        guard canBrowse else { return }
        guard force || Date().timeIntervalSince(lastBadgeFetch) > Self.pollInterval else { return }
        lastBadgeFetch = Date()
        if let b = try? await client.badgeCounts() {
            badge = b
            BadgeShare.save(b)
        }
    }

    func clearNotificationBadge(topCursor: String?) async {
        badge.notifications = 0
        BadgeShare.save(badge)
        if let topCursor { try? await client.markNotificationsSeen(topCursor: topCursor) }
    }
}

#if DEBUG
extension AppModel {
    /// Screenshot/CI harness: behave as logged in with `client` and `viewer`, no network.
    func installDebugSession(client: XClient, viewer: XUser) {
        hasDebugSession = true
        let account = XAccount(
            credentials: XCredentials(authToken: "debug-auth-token", ct0: "debug-ct0", twid: "u=\(viewer.id)"),
            user: viewer)
        self.client = client
        accounts = [account]
        activeAccountId = account.id
        isLoggedIn = true
        self.viewer = viewer
        badge = XBadgeCounts(notifications: 0, dms: 0)
        lastStateChange = Date()
        stateLoaded = true
    }
}
#endif

/// Shares the unread count with widgets/complications via the app group-less
/// standard defaults (the widget reads the same suite when an app group exists).
enum BadgeShare {
    static let key = "perch.badge.notifications"
    static func save(_ b: XBadgeCounts) {
        UserDefaults.standard.set(b.notifications, forKey: key)
    }
}

/// WatchConnectivity dictionaries only contain property-list values; boxed to cross actors.
struct MessageBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}
