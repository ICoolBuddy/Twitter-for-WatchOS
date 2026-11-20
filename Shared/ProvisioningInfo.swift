import Foundation
import XKit

/// The sideloaded app is signed with a free Apple ID, whose provisioning profile
/// expires after 7 days. When it does, the app stops launching — and until now
/// nothing in the app said a word about it.
///
/// The expiry is in the bundle's `embedded.mobileprovision`: a CMS envelope around
/// an XML plist. Only the XML is needed, so this reads the slice between `<?xml`
/// and `</plist>` and asks PropertyListSerialization for it (no CMS/crypto code).
enum ProvisioningInfo {
    struct Info: Equatable {
        var expiresAt: Date?

        /// Whole days left (0 = expires today, negative = already expired).
        var daysLeft: Int? {
            guard let expiresAt else { return nil }
            let seconds = expiresAt.timeIntervalSinceNow
            // An expiry 6 hours ago must read "expired", not "expires today" (ceil(-0.25)
            // is 0 in integer terms).
            guard seconds > 0 else { return -1 }
            return Int(ceil(seconds / 86_400))
        }
    }

    /// Resolved once: the profile does not change while the app runs.
    static let current: Info = load()

    /// Nil when the bundle has no profile (a store build) — the caller shows nothing.
    static func reminder() -> String? {
        guard let left = current.daysLeft else { return nil }
        if left < 0 { return "Signature expired" }
        if left == 0 { return "Signature expires today" }
        return "\(left) day\(left == 1 ? "" : "s") left"
    }

    static func isUrgent(urgentBelow days: Int = 2) -> Bool {
        guard let left = current.daysLeft else { return false }
        return left <= days
    }

    private static func load() -> Info {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // Expected in an unsigned CI archive; unexpected in a sideloaded build, where
            // it is the only thing that can warn before the app stops launching.
            Task { await RequestLog.shared.record(method: "-", url: nil, status: nil,
                                                  durationMs: 0, note: "no embedded.mobileprovision") }
            return Info(expiresAt: nil)
        }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), options: [],
                                   in: start.lowerBound..<data.endIndex) else {
            return Info(expiresAt: nil)
        }
        let xml = Data(data[start.lowerBound..<end.upperBound])
        guard let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil),
              let dict = plist as? [String: Any],
              let expires = dict["ExpirationDate"] as? Date else {
            return Info(expiresAt: nil)
        }
        return Info(expiresAt: expires)
    }
}
