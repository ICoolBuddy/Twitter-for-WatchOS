#if DEBUG
import Foundation
import SwiftUI
import XKit

/// Screens the screenshot harness can open directly with `-PerchScreen <name>`.
enum PerchDebugScreen: String, CaseIterable, Sendable {
    case feed
    case menu
    case post
    case profile
    case media
    case notifications
    case longpost
}

/// Entry points for the DEBUG-only screenshot harness.
///
/// The CI workflow launches the app with `-PerchFixtures YES -PerchScreen feed`
/// (and so on). Everything here is DEBUG-only twice over: project.yml excludes
/// the whole `PerchWatch/Debug` folder from Release builds and each file is also
/// wrapped in `#if DEBUG`.
///
/// Integrator wiring — this is the only required snippet (see the report). The
/// call must be inside `#if DEBUG` because the Debug folder is not compiled in
/// Release:
///
///     WindowGroup {
///         #if DEBUG
///         rootView.perchDebugScreens()
///         #else
///         rootView
///         #endif
///     }
///
/// where `rootView` is the existing `WatchRootView()` chain. Calling
/// `PerchDebug.install()` from `App.init()` is optional and slightly earlier:
///
///     init() {
///         PerchSettings.registerDefaults()
///         #if DEBUG
///         PerchDebug.install()
///         #endif
///     }
/// Last values the crown-refresh and place-restore code computed. Read by the
/// DEBUG probes (`probe.*`, `place.*`) so a CI run can say what the app thought,
/// not only where the list ended up.
enum PerchTrace {
    static var refresh = "-"
    static var place = "-"
}

enum PerchDebug {
    /// `-PerchScreen <name>` (or the `PERCH_SCREEN` environment variable for local use).
    static var screen: PerchDebugScreen? {
        #if DEBUG
        let raw = UserDefaults.standard.string(forKey: "PerchScreen")
            ?? ProcessInfo.processInfo.environment["PERCH_SCREEN"]
        guard let raw else { return nil }
        return PerchDebugScreen(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        #else
        return nil
        #endif
    }

    /// `-PerchFixtures YES`, or any `-PerchScreen`, turns on the fixture session.
    static var fixturesEnabled: Bool {
        #if DEBUG
        if screen != nil { return true }
        return UserDefaults.standard.bool(forKey: "PerchFixtures")
        #else
        return false
        #endif
    }

    /// Installs the fixture session before the first view is built. Optional:
    /// `perchDebugScreens()` installs it after launch too, so the harness still
    /// works if only the modifier is wired.
    @MainActor
    static func install() {
        #if DEBUG
        guard fixturesEnabled else { return }
        FixtureHarness.install(screen: screen)
        #endif
    }
}

extension View {
    /// Root hook for the harness. DEBUG builds only (this whole folder is
    /// excluded from Release by project.yml).
    func perchDebugScreens() -> some View {
        modifier(PerchDebugRootModifier())
    }
}

/// Overlays the requested fixture screen on top of the normal app. An overlay
/// (rather than replacing the root) keeps the harness independent of `isLoggedIn`
/// and of whatever the parallel UI work does to `WatchRootView`.
struct PerchDebugRootModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content.overlay {
            PerchDebugOverlay()
                .environmentObject(AppModel.shared)
                .environmentObject(AppModel.shared.posts)
                .environmentObject(WatchSync.shared)
        }
        #else
        content
        #endif
    }
}
#endif
