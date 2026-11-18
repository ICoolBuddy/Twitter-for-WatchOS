import Foundation

/// What the watch-face complication shows: the unread count plus a preview of
/// the newest post.
///
/// Defined in this one file so the Watch app and the `PerchWidget` extension
/// compile exactly the same type (the widget target only adds this file from
/// `Shared/`, not the whole folder).
struct ComplicationSnapshot: Codable, Equatable, Sendable {
    var unread: Int
    var author: String?
    var text: String?
    var updated: Date

    init(unread: Int = 0, author: String? = nil, text: String? = nil, updated: Date = Date()) {
        self.unread = unread
        self.author = author
        self.text = text
        self.updated = updated
    }

    /// Placeholder / logged-out state: just the bird, no numbers.
    static let empty = ComplicationSnapshot()
}

/// App Group access shared by the Watch app and its complication extension.
///
/// The sideload signer may rewrite bundle identifiers, so the group id is
/// resolved at runtime instead of being hard-coded: first the `PerchAppGroup`
/// Info.plist value, then `group.<bundle id>` with the `.watchkitapp` /
/// `.watchkitapp.widget` suffixes removed. The first candidate that actually
/// has a container wins. Without a container (e.g. app groups unavailable)
/// everything falls back to `UserDefaults.standard`, which the widget does not
/// share — the complication then simply shows the bird.
enum AppGroup {
    static let snapshotKey = "perch.complication.snapshot"

    /// The app group the process is really a member of, if any. Resolved once: the
    /// container lookup used to run on every read and write.
    static let identifier: String? = candidates.first {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
    }

    /// Defaults the app and the widget both read and write.
    static var defaults: UserDefaults {
        if let id = identifier, let shared = UserDefaults(suiteName: id) { return shared }
        return .standard
    }

    static func saveSnapshot(_ snapshot: ComplicationSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    static func loadSnapshot() -> ComplicationSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(ComplicationSnapshot.self, from: data)
    }

    /// Drop the cached snapshot (e.g. after logout) so the complication goes
    /// back to showing only the bird.
    static func clearSnapshot() {
        defaults.removeObject(forKey: snapshotKey)
    }

    /// Most specific candidate first.
    private static var candidates: [String] {
        var ids: [String] = []
        if let configured = Bundle.main.object(forInfoDictionaryKey: "PerchAppGroup") as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { ids.append(trimmed) }
        }
        if let bundleId = Bundle.main.bundleIdentifier {
            var base = bundleId
            for suffix in [".watchkitapp.widget", ".watchkitapp"] {
                if base.hasSuffix(suffix) {
                    base = String(base.dropLast(suffix.count))
                    break
                }
            }
            let derived = "group." + base
            if !ids.contains(derived) { ids.append(derived) }
        }
        return ids
    }
}
