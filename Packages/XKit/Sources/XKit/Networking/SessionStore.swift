import Foundation

/// What changed in the store, so observers update only that (a `ct0` rotation,
/// which nothing displays, emits nothing).
///
/// - `upsertAccount` / `replaceAccounts` / `removeAccount` / `updateUser` /
///   `setCredentials` / `wipe` → `.accounts` (a logout is "the list became empty")
/// - `setActiveAccount` → `.activeAccount`
/// - `setConfig` / `mergeConfig` → `.config`
/// - `setMaterial` → `.material`
/// - `setRemoteOverrideURL` → `.remoteOverride`
/// - `markSessionExpired` → `.sessionExpired`
public enum XSessionEvent: Sendable, Equatable {
    case accounts, activeAccount, config, material, remoteOverride, sessionExpired
}

/// Holds everything a client needs: accounts/credentials (Keychain), endpoint config
/// and transaction material (small JSON files in Application Support).
public actor XSessionStore {
    private let keychain: KeychainStore
    private let directory: URL?
    /// Always mirrors the active account's credentials (nil when there are none).
    public private(set) var credentials: XCredentials?
    public private(set) var accounts: [XAccount]
    public private(set) var activeAccountId: String?
    public private(set) var config: EndpointConfig
    public private(set) var material: TransactionMaterial?
    public private(set) var remoteOverrideURL: URL?
    /// Set by a 401 for the current credentials; cleared by construction when new or
    /// switched credentials arrive. The stored credentials are never touched, so the
    /// Watch can never log the iPhone out.
    public private(set) var sessionExpired = false

    private static let accountsKey = "x-accounts"
    private static let activeKey = "x-active"

    private var observers: [UUID: @Sendable (XSessionEvent) -> Void] = [:]

    public init(keychain: KeychainStore = KeychainStore(), directory: URL? = XSessionStore.defaultDirectory()) {
        self.keychain = keychain
        self.directory = directory
        let loaded = XSessionStore.loadAccounts(from: keychain)
        self.accounts = loaded.accounts
        self.activeAccountId = loaded.activeId
        self.credentials = loaded.accounts.first { $0.id == loaded.activeId }?.credentials
        var cfg = EndpointConfig.bundled
        if let dir = directory, let data = try? Data(contentsOf: dir.appendingPathComponent("endpoints.json")),
           let cached = try? EndpointConfig.decode(data) {
            // Prefer whichever is newer; merging keeps any op only one of them knows.
            cfg = cached.updatedAt >= cfg.updatedAt ? cfg.merging(cached) : cached.merging(cfg)
        }
        self.config = cfg
        if let dir = directory, let data = try? Data(contentsOf: dir.appendingPathComponent("transaction.json")) {
            let stored = try? JSONDecoder.iso.decode(TransactionMaterial.self, from: data)
            self.material = (stored?.isUsable == true) ? stored : nil
        }
        if let dir = directory, let data = try? Data(contentsOf: dir.appendingPathComponent("override-url.txt")),
           let s = String(data: data, encoding: .utf8) {
            self.remoteOverrideURL = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public static func defaultDirectory() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Perch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var isLoggedIn: Bool { credentials != nil }

    public var activeAccount: XAccount? { accounts.first { $0.id == activeAccountId } }

    /// Updates the ACTIVE account's credentials (used for `ct0` rotation) or
    /// upserts when there is no active account yet. `nil` removes all accounts.
    public func setCredentials(_ c: XCredentials?) {
        guard let c else {
            accounts = []
            activeAccountId = nil
            credentials = nil
            keychain.delete(account: Self.accountsKey)
            keychain.delete(account: Self.activeKey)
            notify(.accounts)
            return
        }
        if let id = activeAccountId, let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].credentials = c
            credentials = c
            sessionExpired = false
            persistAccounts()
            notify(.accounts)
        } else {
            upsertAccount(c, user: nil)
        }
    }

    /// Adds or updates an account and makes it active.
    @discardableResult
    public func upsertAccount(_ c: XCredentials, user: XUser?) -> String {
        let id = XAccount.id(for: c)
        if let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].credentials = c
            if let user { accounts[idx].user = user }
        } else {
            accounts.append(XAccount(credentials: c, user: user))
        }
        activeAccountId = id
        credentials = c
        sessionExpired = false
        persistAccounts()
        notify(.accounts)
        return id
    }

    public func setActiveAccount(_ id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        activeAccountId = account.id
        credentials = account.credentials
        sessionExpired = false
        persistAccounts()
        notify(.activeAccount)
    }

    /// Removes one account. If it was active, the next account becomes active (or none).
    public func removeAccount(_ id: String) {
        accounts.removeAll { $0.id == id }
        if activeAccountId == id || activeAccountId == nil { activeAccountId = accounts.first?.id }
        credentials = activeAccount?.credentials
        persistAccounts()
        notify(.accounts)
    }

    /// Replaces the whole list (used by the Watch when the iPhone syncs its accounts).
    /// The current active account is kept when it is still present, else the first wins.
    public func replaceAccounts(_ list: [XAccount]) {
        // A sync delivers the same list again and again: no Keychain write, no event.
        if list == accounts, (list.isEmpty || activeAccountId != nil) { return }
        accounts = list
        if list.isEmpty {
            activeAccountId = nil
        } else if let id = activeAccountId, !list.contains(where: { $0.id == id }) {
            activeAccountId = list.first?.id
        } else if activeAccountId == nil {
            activeAccountId = list.first?.id
        }
        credentials = activeAccount?.credentials
        sessionExpired = false
        persistAccounts()
        notify(.accounts)
    }

    public func updateUser(_ user: XUser, forAccount id: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].user = user
        persistAccounts()
        notify(.accounts)
    }

    /// Called when X rotates `ct0` via Set-Cookie. `authToken` identifies the account
    /// the response belongs to, so a rotation that lands after an account switch cannot
    /// overwrite the new active account's token. No event: nothing displays `ct0`.
    public func updateCt0(_ ct0: String, forAuthToken authToken: String) {
        guard let idx = accounts.firstIndex(where: { $0.credentials.authToken == authToken }),
              accounts[idx].credentials.ct0 != ct0 else { return }
        accounts[idx].credentials.ct0 = ct0
        if accounts[idx].id == activeAccountId { credentials = accounts[idx].credentials }
        persistAccounts()
    }

    /// A 401 for these credentials: one app-wide "session expired" state (see
    /// `sessionExpired`). Ignored for credentials that are no longer stored.
    public func markSessionExpired(forAuthToken authToken: String) {
        guard credentials?.authToken == authToken, !sessionExpired else { return }
        sessionExpired = true
        notify(.sessionExpired)
    }

    public func setConfig(_ c: EndpointConfig) {
        guard c != config else { return }       // ~35 KB file: don't rewrite an identical one
        config = c
        write(c.encoded(), name: "endpoints.json")
        notify(.config)
    }

    public func mergeConfig(_ newer: EndpointConfig) {
        setConfig(config.merging(newer))
    }

    /// Unusable material (e.g. a truncated key from a sync) is stored as absent, so the
    /// next request re-fetches instead of every request failing as a "stale signer".
    public func setMaterial(_ m: TransactionMaterial?) {
        let usable = (m?.isUsable == true) ? m : nil
        if m != nil, usable == nil { note("discarded unusable signing material (\(m?.source ?? "?"))") }
        material = usable
        if let usable, let d = try? JSONEncoder.iso.encode(usable) { write(d, name: "transaction.json") }
        else { remove("transaction.json") }
        notify(.material)
    }

    public func setRemoteOverrideURL(_ url: URL?) {
        remoteOverrideURL = url
        if let url { write(Data(url.absoluteString.utf8), name: "override-url.txt") } else { remove("override-url.txt") }
        notify(.remoteOverride)
    }

    /// Log out: wipe Keychain (all accounts) and cached session material.
    /// Endpoint config is kept (not personal).
    public func wipe() {
        accounts = []
        activeAccountId = nil
        credentials = nil
        sessionExpired = false
        keychain.deleteAll()
        setMaterial(nil)
        notify(.accounts)
    }

    // MARK: Persistence

    private func persistAccounts() {
        if accounts.isEmpty {
            keychain.delete(account: Self.accountsKey)
            keychain.delete(account: Self.activeKey)
            return
        }
        do {
            try keychain.save(try JSONEncoder.iso.encode(accounts), account: Self.accountsKey)
        } catch {
            note("saving accounts to the Keychain failed: \(error)")
        }
        if let id = activeAccountId {
            do { try keychain.save(Data(id.utf8), account: Self.activeKey) }
            catch { note("saving the active account failed: \(error)") }
        } else {
            keychain.delete(account: Self.activeKey)
        }
    }

    private static func loadAccounts(from keychain: KeychainStore) -> (accounts: [XAccount], activeId: String?) {
        if let data = keychain.load(account: accountsKey),
           let decoded = try? JSONDecoder.iso.decode([Lossy<XAccount>].self, from: data) {
            // Element-wise: an account this build cannot read is skipped instead of
            // logging the user out of every account (and it is reported).
            let list = decoded.compactMap(\.value)
            if list.count < decoded.count {
                let lost = decoded.count - list.count
                Task { await RequestLog.shared.record(method: "-", url: nil, status: nil, durationMs: 0,
                                                     note: "\(lost) stored account(s) could not be read") }
            }
            let stored = keychain.load(account: activeKey).flatMap { String(data: $0, encoding: .utf8) }
            let active = stored.flatMap { id in list.contains(where: { $0.id == id }) ? id : nil } ?? list.first?.id
            return (list, active)
        }
        // Migrate the legacy single `x-session` credentials into the account list.
        if let legacy = keychain.loadCredentials() {
            let account = XAccount(credentials: legacy)
            keychain.delete(account: "x-session")
            if let data = try? JSONEncoder.iso.encode([account]) {
                try? keychain.save(data, account: accountsKey)
            }
            try? keychain.save(Data(account.id.utf8), account: activeKey)
            return ([account], account.id)
        }
        return ([], nil)
    }

    @discardableResult
    public func observe(_ f: @escaping @Sendable (XSessionEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = f
        return id
    }

    /// For observers that only need "something changed".
    @discardableResult
    public func observe(_ f: @escaping @Sendable () -> Void) -> UUID {
        observe { (_: XSessionEvent) in f() }
    }

    private func notify(_ event: XSessionEvent) { for o in observers.values { o(event) } }

    /// Breadcrumb in the in-app request log (Settings → Request log).
    private nonisolated func note(_ message: String) {
        Task { await RequestLog.shared.record(method: "-", url: nil, status: nil, durationMs: 0, note: message) }
    }

    private func write(_ data: Data, name: String) {
        guard let dir = directory else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private func remove(_ name: String) {
        guard let dir = directory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
}

/// Decodes `T` but yields `nil` instead of failing the whole collection
/// (`[T?]` would not: an optional element still fails when its decode throws).
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
