import Foundation
import XKit

/// UserDefaults keys shared by the iPhone and Watch apps.
enum PerchSettings {
    /// Refresh the home timeline when the app opens (default ON).
    static let autoRefreshOnOpen = "autoRefreshOnOpen"
    /// Active home timeline (`HomeKind.rawValue`).
    static let homeKind = "homeKind"
    /// Feed text size (`PerchTextSize.rawValue`).
    static let textSize = "textSize"
    /// Videos keep playing in the background through Bluetooth audio (default ON).
    static let backgroundVideo = "backgroundVideo"

    /// Call before any view reads `@AppStorage` values.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoRefreshOnOpen: true,
            homeKind: HomeKind.forYou.rawValue,
            textSize: PerchTextSize.medium.rawValue,
            backgroundVideo: true,
        ])
    }
}

/// Feed text sizes on the Watch (multipliers of the 19 pt base body text).
enum PerchTextSize: String, CaseIterable, Identifiable {
    case small, medium, large, extraLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: return 0.88
        case .medium: return 1
        case .large: return 1.15
        case .extraLarge: return 1.3
        }
    }
}

/// Text that failed to send (a reply or a new post), persisted so it survives a
/// relaunch or the row being recycled by the LazyVStack. The system text input
/// cannot be pre-filled, so this is the only draft that exists: the one you already
/// dictated once.
enum DraftStore {
    private static func key(replyTo: String?) -> String {
        replyTo.map { "perch.replyDraft.\($0)" } ?? "perch.postDraft"
    }
    /// A draft that can never be sent from the Watch (over the limit). Remembering
    /// this separately is what stops the row from offering a retry that fails again.
    private static func tooLongKey(_ replyTo: String?) -> String { key(replyTo: replyTo) + ".tooLong" }

    static func failed(replyTo: String?) -> String? {
        UserDefaults.standard.string(forKey: key(replyTo: replyTo))
    }

    /// True when the stored draft is over the limit: it must be edited on the iPhone,
    /// not retried here.
    static func isTooLong(_ replyTo: String?) -> Bool {
        UserDefaults.standard.bool(forKey: tooLongKey(replyTo))
    }

    static func saveFailed(_ text: String, replyTo: String?, tooLong: Bool = false) {
        UserDefaults.standard.set(text, forKey: key(replyTo: replyTo))
        UserDefaults.standard.set(tooLong, forKey: tooLongKey(replyTo))
    }

    static func clear(replyTo: String?) {
        UserDefaults.standard.removeObject(forKey: key(replyTo: replyTo))
        UserDefaults.standard.removeObject(forKey: tooLongKey(replyTo))
    }
}

/// X's standard post limit. The watch cannot edit a failed text in place, so it is
/// checked before sending; the message says how far over it is and where to fix it.
enum TweetText {
    static let limit = 280

    static func tooLong(_ text: String) -> String? {
        text.count > limit ? "Too long · \(text.count)/\(limit) — edit on iPhone" : nil
    }
}
