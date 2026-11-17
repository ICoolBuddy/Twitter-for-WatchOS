import Foundation

/// What the iPhone sends to the Watch over WatchConnectivity.
/// Encoded as a single `Data` blob under `SyncPayload.key` in the userInfo /
/// application context dictionaries.
public struct SyncPayload: Codable, Sendable, Equatable {
    public static let key = "perch.sync"

    public enum Command: String, Codable, Sendable {
        case update   // credentials/config/material changed
        case logout   // wipe everything
    }

    public var command: Command
    public var credentials: XCredentials?
    /// All accounts known to the iPhone. `nil` in payloads from older builds.
    public var accounts: [XAccount]?
    public var config: EndpointConfig?
    public var material: TransactionMaterial?
    public var remoteOverrideURL: String?
    public var sentAt: Date

    public init(command: Command, credentials: XCredentials? = nil, accounts: [XAccount]? = nil,
                config: EndpointConfig? = nil, material: TransactionMaterial? = nil,
                remoteOverrideURL: String? = nil, sentAt: Date = Date()) {
        self.command = command; self.credentials = credentials; self.accounts = accounts
        self.config = config; self.material = material
        self.remoteOverrideURL = remoteOverrideURL; self.sentAt = sentAt
    }

    public func encoded() throws -> Data { try JSONEncoder.iso.encode(self) }

    public static func decode(_ data: Data) throws -> SyncPayload { try JSONDecoder.iso.decode(SyncPayload.self, from: data) }

    public func dictionary() -> [String: Any] {
        guard let d = try? encoded() else { return [:] }
        return [Self.key: d]
    }

    public static func from(dictionary: [String: Any]) -> SyncPayload? {
        guard let d = dictionary[key] as? Data else { return nil }
        return try? decode(d)
    }

    /// Applies the payload to a session store. Newer-wins for config.
    public func apply(to store: XSessionStore) async {
        switch command {
        case .logout:
            await store.wipe()
        case .update:
            if let accounts {
                await store.replaceAccounts(accounts)
            } else if let credentials {
                // Payload from an older iPhone build: a single account.
                _ = await store.upsertAccount(credentials, user: nil)
            }
            if let config { await store.mergeConfig(config) }
            if let material { await store.setMaterial(material) }
            if let remoteOverrideURL { await store.setRemoteOverrideURL(URL(string: remoteOverrideURL)) }
        }
    }
}

/// Fetches an `endpoints.json` override (e.g. a raw GitHub URL).
public enum RemoteOverride {
    public static func fetch(_ url: URL, transport: HTTPTransport = URLSessionTransport()) async throws -> EndpointConfig {
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await transport.send(req)
        await RequestLog.shared.record(method: "GET", url: url, status: resp.statusCode, durationMs: 0, note: "override")
        guard (200..<300).contains(resp.statusCode) else { throw XError.server(resp.statusCode) }
        do { return try EndpointConfig.decode(data) } catch { throw XError.decoding("endpoints.json: \(error)") }
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
