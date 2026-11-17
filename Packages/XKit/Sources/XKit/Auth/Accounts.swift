import Foundation

/// One logged-in X account.
///
/// `id` is the numeric X user id when it is known (`credentials.userId`), otherwise
/// a stable `local-<16 hex>` hash of `authToken`. That way the same cookie pair always
/// maps to the same account even before the viewer profile has been fetched.
public struct XAccount: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var credentials: XCredentials
    /// Cached profile (name, handle, avatar) for the account pickers.
    public var user: XUser?

    public init(credentials: XCredentials, user: XUser? = nil) {
        self.credentials = credentials
        self.user = user
        self.id = XAccount.id(for: credentials)
    }

    public static func id(for c: XCredentials) -> String {
        if let uid = c.userId, !uid.isEmpty { return uid }
        let digest = Hashing.sha256(Array(c.authToken.utf8))
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "local-" + hex
    }
}
