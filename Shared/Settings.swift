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

    /// Call before any view reads `@AppStorage` values.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoRefreshOnOpen: true,
            homeKind: HomeKind.forYou.rawValue,
            textSize: PerchTextSize.medium.rawValue,
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
