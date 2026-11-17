import Foundation

/// Holds everything a client needs: credentials (Keychain), endpoint config
/// and transaction material (small JSON files in Application Support).
public actor XSessionStore {
    private let keychain: KeychainStore
    private let directory: URL?
    public private(set) var credentials: XCredentials?
    public private(set) var config: EndpointConfig
    public private(set) var material: TransactionMaterial?
    public private(set) var remoteOverrideURL: URL?

    private var observers: [UUID: @Sendable () -> Void] = [:]

    public init(keychain: KeychainStore = KeychainStore(), directory: URL? = XSessionStore.defaultDirectory()) {
        self.keychain = keychain
        self.directory = directory
        self.credentials = keychain.loadCredentials()
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

    public func setCredentials(_ c: XCredentials?) {
        credentials = c
        if let c { try? keychain.saveCredentials(c) } else { keychain.delete(account: "x-session") }
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

    /// Log out: wipe Keychain and cached session material. Endpoint config is kept (not personal).
    public func wipe() {
        credentials = nil
        keychain.deleteAll()
        setMaterial(nil)
        notify()
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
