import Foundation
#if canImport(Security)
import Security
#endif

/// The browser session cookies Perch authenticates with.
public struct XCredentials: Codable, Sendable, Hashable {
    public var authToken: String
    public var ct0: String
    public var twid: String?

    public init(authToken: String, ct0: String, twid: String? = nil) {
        self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ct0 = ct0.trimmingCharacters(in: .whitespacesAndNewlines)
        self.twid = twid?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Basic sanity check: auth_token is 40 hex chars, ct0 is 32–160 hex chars.
    public var looksValid: Bool {
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        func isHex(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy(hex.contains) }
        return isHex(authToken) && authToken.count >= 20 && isHex(ct0) && ct0.count >= 32
    }

    /// Numeric user id from `twid` ("u%3D123" / "u=123").
    public var userId: String? {
        guard let twid else { return nil }
        let decoded = twid.removingPercentEncoding ?? twid
        if decoded.hasPrefix("u=") { return String(decoded.dropFirst(2)) }
        return decoded.allSatisfy(\.isNumber) ? decoded : nil
    }

    public var cookieHeader: String {
        var parts = ["auth_token=\(authToken)", "ct0=\(ct0)"]
        if let twid, !twid.isEmpty { parts.append("twid=\(twid)") }
        return parts.joined(separator: "; ")
    }
}

/// Removes secrets from strings before they are logged or displayed.
public enum Redactor {
    public static func redact(_ s: String, credentials: XCredentials? = nil) -> String {
        var out = s
        if let c = credentials {
            for secret in [c.authToken, c.ct0] where secret.count >= 8 {
                out = out.replacingOccurrences(of: secret, with: mask(secret))
            }
        }
        // Generic patterns: cookie values and csrf headers.
        for key in ["auth_token", "ct0", "kdt", "att", "twid"] {
            out = replacePattern(in: out, pattern: "\(key)=([^;\\s&\"]+)") { "\(key)=\(mask($0))" }
        }
        out = replacePattern(in: out, pattern: "(?i)x-csrf-token: ?([0-9a-f]+)") { "x-csrf-token: \(mask($0))" }
        return out
    }

    public static func mask(_ s: String) -> String {
        guard s.count > 6 else { return "•••" }
        return String(s.prefix(3)) + "…[\(s.count)]"
    }

    static func replacePattern(in s: String, pattern: String, _ transform: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += transform(ns.substring(with: m.range(at: 1)))
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}

/// Keychain-backed storage for credentials and small secrets.
/// (The Keychain is per device; iPhone → Watch sync happens via WatchConnectivity.)
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "perch.credentials") { self.service = service }

    public func save(_ data: Data, account: String) throws {
        #if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(Int(status)) }
        #else
        KeychainStore.memory.set(data, for: service + "/" + account)
        #endif
    }

    public func load(account: String) -> Data? {
        #if canImport(Security)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
        #else
        return KeychainStore.memory.get(service + "/" + account)
        #endif
    }

    public func delete(account: String) {
        #if canImport(Security)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        #else
        KeychainStore.memory.set(nil, for: service + "/" + account)
        #endif
    }

    public func deleteAll() {
        #if canImport(Security)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(q as CFDictionary)
        #else
        KeychainStore.memory.removeAll(prefix: service + "/")
        #endif
    }

    // MARK: Credentials convenience

    public func saveCredentials(_ c: XCredentials) throws {
        try save(try JSONEncoder().encode(c), account: "x-session")
    }

    public func loadCredentials() -> XCredentials? {
        load(account: "x-session").flatMap { try? JSONDecoder().decode(XCredentials.self, from: $0) }
    }

    #if !canImport(Security)
    /// In-memory stand-in so the package builds and tests on Linux.
    final class Memory: @unchecked Sendable {
        private var store: [String: Data] = [:]
        private let lock = NSLock()
        func set(_ d: Data?, for k: String) { lock.lock(); store[k] = d; lock.unlock() }
        func get(_ k: String) -> Data? { lock.lock(); defer { lock.unlock() }; return store[k] }
        func removeAll(prefix: String) { lock.lock(); store = store.filter { !$0.key.hasPrefix(prefix) }; lock.unlock() }
    }
    static let memory = Memory()
    #endif
}

public enum KeychainError: Error, Sendable {
    case status(Int)
}
