import Foundation

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

    private static let accountsKey = "x-accounts"
    private static let activeKey = "x-active"

    private var observers: [UUID: @Sendable () -> Void] = [:]

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
            self.material = try? JSONDecoder.iso.decode(TransactionMaterial.self, from: data)
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
            notify()
            return
        }
        if let id = activeAccountId, let idx = accounts.firstIndex(where: { $0.id == id }) {
            accounts[idx].credentials = c
            credentials = c
            persistAccounts()
            notify()
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
        persistAccounts()
        notify()
        return id
    }

    public func setActiveAccount(_ id: String) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        activeAccountId = account.id
        credentials = account.credentials
        persistAccounts()
        notify()
    }

    /// Removes one account. If it was active, the next account becomes active (or none).
    public func removeAccount(_ id: String) {
        accounts.removeAll { $0.id == id }
        if activeAccountId == id || activeAccountId == nil { activeAccountId = accounts.first?.id }
        credentials = activeAccount?.credentials
        persistAccounts()
        notify()
    }

    /// Replaces the whole list (used by the Watch when the iPhone syncs its accounts).
    /// The current active account is kept when it is still present, else the first wins.
    public func replaceAccounts(_ list: [XAccount]) {
        accounts = list
        if list.isEmpty {
            activeAccountId = nil
        } else if let id = activeAccountId, !list.contains(where: { $0.id == id }) {
            activeAccountId = list.first?.id
        } else if activeAccountId == nil {
            activeAccountId = list.first?.id
        }
        credentials = activeAccount?.credentials
        persistAccounts()
        notify()
    }

    public func updateUser(_ user: XUser, forAccount id: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].user = user
        persistAccounts()
        notify()
    }

    /// Called when X rotates `ct0` via Set-Cookie.
    public func updateCt0(_ ct0: String) {
        guard var c = credentials, c.ct0 != ct0 else { return }
        c.ct0 = ct0
        setCredentials(c)
    }

    public func setConfig(_ c: EndpointConfig) {
        config = c
        write(c.encoded(), name: "endpoints.json")
        notify()
    }

    public func mergeConfig(_ newer: EndpointConfig) {
        setConfig(config.merging(newer))
    }

    public func setMaterial(_ m: TransactionMaterial?) {
        material = m
        if let m, let d = try? JSONEncoder.iso.encode(m) { write(d, name: "transaction.json") }
        else { remove("transaction.json") }
        notify()
    }

    public func setRemoteOverrideURL(_ url: URL?) {
        remoteOverrideURL = url
        if let url { write(Data(url.absoluteString.utf8), name: "override-url.txt") } else { remove("override-url.txt") }
        notify()
    }

    /// Log out: wipe Keychain (all accounts) and cached session material.
    /// Endpoint config is kept (not personal).
    public func wipe() {
        accounts = []
        activeAccountId = nil
        credentials = nil
        keychain.deleteAll()
        setMaterial(nil)
        notify()
    }

    // MARK: Persistence

    private func persistAccounts() {
        if accounts.isEmpty {
            keychain.delete(account: Self.accountsKey)
            keychain.delete(account: Self.activeKey)
            return
        }
        if let data = try? JSONEncoder.iso.encode(accounts) {
            try? keychain.save(data, account: Self.accountsKey)
        }
        if let id = activeAccountId {
            try? keychain.save(Data(id.utf8), account: Self.activeKey)
        } else {
            keychain.delete(account: Self.activeKey)
        }
    }

    private static func loadAccounts(from keychain: KeychainStore) -> (accounts: [XAccount], activeId: String?) {
        if let data = keychain.load(account: accountsKey),
           let list = try? JSONDecoder.iso.decode([XAccount].self, from: data) {
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
    public func observe(_ f: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        observers[id] = f
        return id
    }

    private func notify() { for o in observers.values { o() } }

    private func write(_ data: Data, name: String) {
        guard let dir = directory else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    private func remove(_ name: String) {
        guard let dir = directory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }
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
