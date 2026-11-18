import Foundation
import SwiftUI

/// Digital Crown routing experiments (crown-lab phase 2, 2026-11-18).
///
/// Each letter switches on one candidate fix, so a single CI run can measure several
/// of them side by side with the UI tests in `PerchWatchUITests/CrownRoutingTests.swift`
/// (`.github/workflows/crown.yml` runs one job per variant):
///
/// - `P` pager: only the page on screen is in the view tree once the pager is at rest
///   (the neighbours exist only while a swipe or a page animation is running), instead
///   of three live pages with the off-screen two `.disabled`.
/// - `S` pager: off-screen pages get `.scrollDisabled` instead of `.disabled`.
/// - `T` pager: the system pager, `TabView` with `.page` style.
/// - `M` media viewer: presented with `fullScreenCover` instead of the overlay.
/// - `F` the leading toolbar button (hamburger / back to feed) is `.focusable(false)`.
/// - `R` rebuild: after a page change, a pop back to the root, a sheet closing or the
///   media viewer closing, the visible feed's ScrollView gets a new identity, so it
///   *appears* again (a feed that appears gets the crown: baseline S1), keeping the
///   list and the page's state.
///
/// DEBUG builds read `-crownVariant <letters>` (UserDefaults argument domain); Release
/// builds always use `shipped`. When a winner is picked it becomes `shipped`, and the
/// losing branches are deleted.
enum CrownLab {
    /// The variant Release builds run. "A" = none of the experiments.
    static let shipped = "A"

    static let variant: String = {
        #if DEBUG
        if let v = UserDefaults.standard.string(forKey: "crownVariant"), !v.isEmpty { return v }
        #endif
        return shipped
    }()

    static func has(_ flag: Character) -> Bool { variant.contains(flag) }

    static var pagerOnlyVisible: Bool { has("P") }
    static var pagerScrollDisabled: Bool { has("S") }
    static var pagerTabView: Bool { has("T") }
    static var mediaCover: Bool { has("M") }
    static var chromeUnfocusable: Bool { has("F") }
    static var rebuildOnReturn: Bool { has("R") }
}

/// `F`: `.focusable(false)` only when the experiment is on, so variant "A" stays the
/// shipped code exactly (a plain `.focusable(true)` would be a change of its own).
struct CrownLabUnfocusable: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.focusable(false)
        } else {
            content
        }
    }
}

/// `R`: bumped by `RootPager` when a feed becomes the visible scroll view again.
private struct CrownGenerationKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var crownGeneration: Int {
        get { self[CrownGenerationKey.self] }
        set { self[CrownGenerationKey.self] = newValue }
    }
}

/// `R`: a new identity for the scroll view on every generation; nothing otherwise.
struct CrownLabRebuild: ViewModifier {
    let generation: Int

    func body(content: Content) -> some View {
        if CrownLab.rebuildOnReturn {
            content.id(generation)
        } else {
            content
        }
    }
}
