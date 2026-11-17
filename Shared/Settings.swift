import Foundation
import XKit

/// UserDefaults keys shared by the iPhone and Watch apps.
enum PerchSettings {
    /// Refresh the home timeline when the app opens (default ON).
    static let autoRefreshOnOpen = "autoRefreshOnOpen"
    /// Active home timeline (`HomeKind.rawValue`).
    static let homeKind = "homeKind"

    /// Call before any view reads `@AppStorage` values.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoRefreshOnOpen: true,
            homeKind: HomeKind.forYou.rawValue,
        ])
    }
}
