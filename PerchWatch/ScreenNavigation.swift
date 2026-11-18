import SwiftUI

// Navigation facts that screens need, published through the environment so the
// ~16 call sites of `swipeBack()`/`postPresentation` do not have to thread them
// by hand.
//
// NOTE on the Digital Crown: there is deliberately no crown focus helper here.
// watchOS routes the crown to the scroll view that is visible by itself; an
// explicit `@FocusState`/`.focusable()`/`resetFocus` on a scroll view *suppresses*
// that routing, and every attempt to re-claim focus on a timer produced a crown
// that only came back after a touch (cold launch, after a post, after a page
// swipe, after the media viewer: all of it). The one thing the layout must
// guarantee is that only the visible screen is an enabled, scrollable view —
// which the pager's `.disabled(page != n)` and the media viewer's
// `focusable(isActive)` already do.
//
// Apple's own crown samples use `.focusable()` only next to
// `digitalCrownRotation(_:)` (the media viewer's pages), never on a plain
// ScrollView.

private struct PopScreenKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }

extension EnvironmentValues {
    /// Set by `RouteView`. `SwipeBack` prefers it over `dismiss()`, so a popped
    /// screen is a state change (`path.removeLast()`) instead of an environment
    /// command that can race the system's own pop. Sheets have none and dismiss
    /// normally.
    var popScreen: (() -> Void)? {
        get { self[PopScreenKey.self] }
        set { self[PopScreenKey.self] = newValue }
    }
}

private struct PushProfileKey: EnvironmentKey { static let defaultValue: ((ProfileTarget) -> Void)? = nil }

extension EnvironmentValues {
    /// Set by a sheet's stack: a profile opened inside a sheet is pushed there
    /// instead of presenting a second sheet (two sheets would each draw a media
    /// host, and the viewer would play twice).
    var pushProfile: ((ProfileTarget) -> Void)? {
        get { self[PushProfileKey.self] }
        set { self[PushProfileKey.self] = newValue }
    }
}
