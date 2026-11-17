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
    let posts = PostStateStore()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var client: XClient
    @Published private(set) var badge = XBadgeCounts(notifications: 0, dms: 0)
    @Published private(set) var viewer: XUser?
    @Published private(set) var endpointsUpdatedAt = ""
    @Published private(set) var materialSummary = "none"
    @Published private(set) var remoteOverrideURL: URL?
    @Published private(set) var lastStateChange = Date()
    @Published var busyMessage: String?

    weak var sync: SyncChannel?
    private var lastBadgeFetch: Date = .distantPast
    /// Never poll X more often than this in the background.
    static let pollInterval: TimeInterval = 15 * 60

    private init() {
        let store = XSessionStore()
        self.store = store
        client = Self.makeClient(store: store)
        UserDefaults.standard.removeObject(forKey: "demoMode")  // left over from the removed demo mode
        Task { [weak self] in
            await store.observe { Task { @MainActor in await AppModel.shared.reloadState() } }
            await self?.reloadState()
        }
    }

    var canBrowse: Bool { isLoggedIn }

    func reloadState() async {
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
        if wasLoggedIn != isLoggedIn { rebuildClient() }
        lastStateChange = Date()
    }

    private static func makeClient(store: XSessionStore) -> XClient {
        LiveXClient(store: store, refreshMaterial: {
            let creds = await store.credentials
            let cfg = await store.config
            return try await TransactionMaterialFetcher(credentials: creds, config: cfg).fetch()
        })
    }

    private func rebuildClient() {
        client = Self.makeClient(store: store)
        viewer = nil
    }

    // MARK: Account

    func login(_ creds: XCredentials) async {
        await store.setCredentials(creds)
        await reloadState()
        sync?.syncNow()
        // Signing material makes some endpoints (search) work; best effort.
        Task { try? await self.refreshMaterial() }
    }

    func logout(propagate: Bool = true) async {
        await store.wipe()
        TimelineDiskCache.clear()
        posts.reset()
        badge = XBadgeCounts(notifications: 0, dms: 0)
        viewer = nil
        await reloadState()
        if propagate { sync?.sendLogout() }
    }

    func loadViewer() async {
        guard canBrowse, viewer == nil else { return }
        viewer = try? await client.viewer()
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
                #if os(watchOS)
                var discovery = EndpointDiscovery()
                discovery.maxChunks = 25
                #else
                let discovery = EndpointDiscovery()
                #endif
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
        let creds = await store.credentials
        let cfg = await store.config
        let m = try await TransactionMaterialFetcher(credentials: creds, config: cfg).fetch()
        await store.setMaterial(m)
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
