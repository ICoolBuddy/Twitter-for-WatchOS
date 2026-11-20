import Foundation
import SwiftUI
import XKit

/// Implemented by the platform-specific WatchConnectivity bridges.
@MainActor
protocol SyncChannel: AnyObject {
    /// iPhone: push the current state now (it also pushes by itself whenever the synced
    /// state changes). Watch: ask the iPhone for it.
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
    /// The active account's profile. Only `AppModel` fetches it (`loadViewer`).
    @Published private(set) var viewer: XUser?
    /// Why the last viewer fetch failed (nil after a success); `.relogin` means the
    /// session really is dead.
    @Published private(set) var viewerError: XError?
    @Published private(set) var endpointsUpdatedAt = ""
    @Published private(set) var materialSummary = "none"
    @Published private(set) var remoteOverrideURL: URL?
    /// X answered 401 for the active credentials. Cleared by the store when new or
    /// switched credentials arrive; the credentials themselves are never touched.
    @Published private(set) var sessionExpired = false
    @Published var busyMessage: String?
    /// True once the first `reloadState()` has read the stored session (before
    /// that `isLoggedIn` is false even for a logged-in user).
    @Published private(set) var stateLoaded = false

    weak var sync: SyncChannel?
    /// Platform hook run on logout (the Watch clears its offline caches).
    var onLogout: (() -> Void)?
    /// The active account changed (or was first read): per-account caches switch.
    var onActiveAccountChange: ((String?) -> Void)?
    /// An account was removed: its per-account caches must go.
    var onAccountRemoved: ((String) -> Void)?
    /// The account `viewer` belongs to (nil = no viewer).
    private var viewerAccountId: String?
    private var viewerTask: Task<Void, Never>?
    private var viewerLoadToken: UUID?
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
        posts.attach(client)
        UserDefaults.standard.removeObject(forKey: "demoMode")  // left over from the removed demo mode
        Task { [weak self] in
            await store.observe { (event: XSessionEvent) in
                Task { @MainActor in await AppModel.shared.apply(event) }
            }
            await self?.reloadState()
        }
    }

    var canBrowse: Bool { isLoggedIn }

    var activeAccount: XAccount? { accounts.first { $0.id == activeAccountId } }

    /// Updates only what a store event can have changed (a signing-key refresh does not
    /// republish the accounts, and a ct0 rotation emits nothing at all).
    func apply(_ event: XSessionEvent) async {
        switch event {
        case .material:
            await reloadMaterialSummary()
        case .sessionExpired:
            let expired = await store.sessionExpired
            if sessionExpired != expired { sessionExpired = expired }
            // Ask the iPhone once for fresh credentials; nothing is wiped here.
            if expired { sync?.syncNow() }
        case .credentials:
            // Nothing on screen shows ct0; the sync bridge hears the event and sends it.
            break
        case .accounts, .activeAccount, .config, .remoteOverride:
            await reloadState()
        }
    }

    /// Reads the stored session. Assigns only values that changed, so a burst of store
    /// events (one sync payload writes several things) does not redraw the whole app
    /// for each of them.
    func reloadState() async {
        #if DEBUG
        if hasDebugSession { return }
        #endif
        let newAccounts = await store.accounts
        if accounts != newAccounts { accounts = newAccounts }
        let newActive = await store.activeAccountId
        if activeAccountId != newActive {
            activeAccountId = newActive
            // The badge belongs to the account, not the device.
            badge = XBadgeCounts(notifications: 0, dms: 0)
            lastBadgeFetch = .distantPast
        }
        // Offline taps are queued per account: only the active one's replay, and the
        // queues of accounts that no longer exist are dropped.
        posts.setAccount(activeAccountId)
        posts.dropQueues(notIn: Set(newAccounts.map(\.id)))
        onActiveAccountChange?(activeAccountId)
        let creds = await store.credentials
        let wasLoggedIn = isLoggedIn
        if isLoggedIn != (creds != nil) { isLoggedIn = creds != nil }
        let updatedAt = await store.config.updatedAt
        if endpointsUpdatedAt != updatedAt { endpointsUpdatedAt = updatedAt }
        let override = await store.remoteOverrideURL
        if remoteOverrideURL != override { remoteOverrideURL = override }
        let expired = await store.sessionExpired
        if sessionExpired != expired { sessionExpired = expired }
        await reloadMaterialSummary()
        if wasLoggedIn != isLoggedIn { rebuildClient() }
        // The viewer belongs to one account: a synced/removed account change drops it.
        if viewerAccountId != activeAccountId { setViewer(nil, for: nil) }
        if viewer == nil, let cached = activeAccount?.user { setViewer(cached, for: activeAccountId) }
        if viewer == nil, canBrowse { startViewerLoad() }
        if !stateLoaded { stateLoaded = true }
    }

    private func reloadMaterialSummary() async {
        let summary = await store.material.map { "\($0.source), \(RelativeTime.short($0.fetchedAt)) ago" } ?? "none"
        if materialSummary != summary { materialSummary = summary }
    }

    private static func makeClient(store: XSessionStore, provider: TransactionMaterialProvider) -> XClient {
        LiveXClient(store: store, refreshMaterial: { try await provider.material(force: true) })
    }

    private func rebuildClient() {
        client = Self.makeClient(store: store, provider: materialProvider)
        posts.attach(client)
        setViewer(nil, for: nil)
    }

    private func setViewer(_ u: XUser?, for accountId: String?) {
        viewerTask?.cancel()
        viewerTask = nil
        if viewer != u { viewer = u }
        viewerAccountId = u == nil ? nil : accountId
        if u != nil { viewerError = nil }
    }

    // MARK: Account

    enum LoginOutcome: Equatable {
        /// X answered with the profile: the session works.
        case verified
        /// Saved, but X could not be asked (offline, rate limit, server): retried later.
        case unverified(XError)
        /// X rejected the cookies; the account was not kept.
        case rejected
    }

    /// Stores the account and verifies it with one authenticated request (the profile,
    /// which the account pickers need anyway). Only a definitive auth rejection removes
    /// it again; a 403 here usually means stale signing material, not a bad session.
    @discardableResult
    func login(_ creds: XCredentials) async -> LoginOutcome {
        // Re-entering an account that is already stored must not delete the working
        // one when the new cookies are rejected (the old ones are restored).
        let previous = await store.accounts.first { $0.id == XAccount.id(for: creds) }
        let id = await store.upsertAccount(creds, user: previous?.user)
        rebuildClient()
        await reloadState()                  // starts the profile fetch (unless cached)
        await viewerTask?.value
        // Signing material makes some endpoints (search) work; best effort.
        Task { try? await self.refreshMaterial() }
        if viewer != nil, activeAccountId == id { return .verified }
        let error = viewerError ?? .network("No response")
        if error == .unauthorized || error == .notLoggedIn {
            if let previous {
                _ = await store.upsertAccount(previous.credentials, user: previous.user)
            } else {
                await store.removeAccount(id)
            }
            await reloadState()
            return .rejected
        }
        return .unverified(error)
    }

    /// Switches the device-local active account. The other device keeps its own.
    /// Which timeline it opens on is the UI's decision (the Watch menu picks For You).
    func switchAccount(to id: String) async {
        guard id != activeAccountId else { return }
        await store.setActiveAccount(id)
        badge = XBadgeCounts(notifications: 0, dms: 0)
        lastBadgeFetch = .distantPast
        posts.reset()
        rebuildClient()
        await reloadState()
    }

    func removeAccount(_ id: String) async {
        let wasActive = activeAccountId == id
        await store.removeAccount(id)
        TimelineDiskCache.clear(account: id)
        posts.dropQueue(accountId: id)
        onAccountRemoved?(id)
        if wasActive {
            badge = XBadgeCounts(notifications: 0, dms: 0)
            lastBadgeFetch = .distantPast
            posts.reset()
            rebuildClient()
        }
        await reloadState()
    }

    /// `propagate`: tell the other device to log out too (the iPhone's own sync would
    /// also send the empty state; the Watch can only tell the iPhone this way).
    func logout(propagate: Bool = true) async {
        await store.wipe()
        TimelineDiskCache.clearAll()
        posts.reset()
        posts.clearQueue()
        onLogout?()
        badge = XBadgeCounts(notifications: 0, dms: 0)
        setViewer(nil, for: nil)
        viewerError = nil
        await reloadState()
        if propagate { sync?.sendLogout() }
    }

    /// One viewer fetch at a time, owned here (screens don't ask for it).
    private func startViewerLoad() {
        guard viewerTask == nil else { return }
        let token = UUID()
        viewerLoadToken = token
        viewerTask = Task { [weak self] in
            await self?.loadViewer()
            // Only clear our own handle: a cancelled load must not clear the next one's.
            if self?.viewerLoadToken == token { self?.viewerTask = nil }
        }
    }

    /// Fetches the active account's profile and stores it with that account. A response
    /// that arrives after the account changed is dropped (it would otherwise be saved as
    /// the new account's profile).
    private func loadViewer() async {
        guard canBrowse, viewer == nil, let accountId = activeAccountId else { return }
        let client = self.client
        do {
            let v = try await client.viewer()
            guard !Task.isCancelled, accountId == activeAccountId else { return }
            viewer = v
            viewerAccountId = accountId
            viewerError = nil
            await store.updateUser(v, forAccount: accountId)
        } catch {
            guard !Task.isCancelled, accountId == activeAccountId else { return }
            viewerError = XError.from(error)
        }
    }

    /// Disk cache scope of a home timeline of the active account.
    func homeCacheScope(_ kind: HomeKind) -> TimelineCacheScope {
        .home(account: activeAccountId ?? "none", kind: kind)
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
        if let lastError { throw lastError }
    }

    func refreshMaterial() async throws {
        try await materialProvider.material(force: true)
        await reloadMaterialSummary()
    }

    func setRemoteOverride(_ s: String) async {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        await store.setRemoteOverrideURL(trimmed.isEmpty ? nil : URL(string: trimmed))
        await reloadState()
    }

    // MARK: Badge

    /// Throttled to one request per 15 minutes unless `force`.
    func refreshBadge(force: Bool = false) async {
        guard canBrowse else { return }
        guard force || Date().timeIntervalSince(lastBadgeFetch) > Self.pollInterval else { return }
        lastBadgeFetch = Date()
        if let b = try? await client.badgeCounts(), b != badge { badge = b }
    }

    func clearNotificationBadge(topCursor: String?) async {
        // Mark on X first: zeroing locally and swallowing the failure made the badge
        // come back on the next poll (the user had already read the list).
        if let topCursor {
            do { try await client.markNotificationsSeen(topCursor: topCursor) }
            catch { return }
        }
        badge.notifications = 0
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
        viewerAccountId = account.id
        badge = XBadgeCounts(notifications: 0, dms: 0)
        stateLoaded = true
    }
}
#endif

/// WatchConnectivity dictionaries only contain property-list values; boxed to cross actors.
struct MessageBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
}
