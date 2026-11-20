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

    static func failed(replyTo: String?) -> String? {
        UserDefaults.standard.string(forKey: key(replyTo: replyTo))
    }

    static func saveFailed(_ text: String, replyTo: String?) {
        UserDefaults.standard.set(text, forKey: key(replyTo: replyTo))
    }

    static func clear(replyTo: String?) {
        UserDefaults.standard.removeObject(forKey: key(replyTo: replyTo))
    }
}

/// X's standard post limit. The watch cannot edit a failed text in place, so it is
/// checked before sending; the message says how far over it is.
enum TweetText {
    static let limit = 280

    static func tooLong(_ text: String) -> String? {
        text.count > limit ? "Too long · \(text.count)/\(limit). Tap to retry" : nil
    }
}
