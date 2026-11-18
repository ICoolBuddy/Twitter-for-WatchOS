import SwiftUI

/// "A presentation that owned the crown has finished going away." One signal for
/// the media viewer (root overlay **and** a cover), the profile sheet and the
/// account picker, so the screen behind them can reclaim the crown the same
/// way. An event counter, not state: nothing derives UI from it.
@MainActor
final class CrownFocusMark: ObservableObject {
    static let shared = CrownFocusMark()
    @Published private(set) var generation = 0

    func mark() { generation &+= 1 }
}

// MARK: - Navigation facts the crown needs

private struct ScreenIsTopKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False for a screen that a pushed screen is covering. Set by `RouteView`;
    /// pager pages get the equivalent through `CrownScrollFocus(active:)`.
    var screenIsTop: Bool {
        get { self[ScreenIsTopKey.self] }
        set { self[ScreenIsTopKey.self] = newValue }
    }
}

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

/// Gives the Digital Crown back to this screen's scroll view — declaratively.
///
/// The crown goes to the focused view, and SwiftUI hands a `ScrollView`/`List`
/// the crown by itself once it is the target; a touch is what normally makes it
/// the target. What the system does *not* do is re-run that decision when a
/// screen comes back from a pushed screen, when the media viewer goes away or
/// when a pager page slides in: Apple documents that default focus is evaluated
/// "when the window first appears, and when a focus state binding update moves
/// focus automatically, but not when responding to user-driven navigation
/// commands" (`defaultFocus(_:_:priority:)`).
///
/// So this does not assign focus from a timer. It declares the scroll view as
/// the default-focus candidate of a focus scope that belongs to *this* screen,
/// and asks the focus system to re-evaluate that scope when the screen becomes
/// the visible one. `resetFocus(in:)` is documented for exactly that, it is
/// scoped (a screen underneath a pushed one cannot win it), and it is
/// synchronous — no delay, and no Boolean that can go stale.
struct CrownScrollFocus<Content: View>: View {
    /// False for a pager page that is off screen.
    var active: Bool
    private let content: Content

    @Namespace private var scope
    @Environment(\.resetFocus) private var resetFocus
    /// False while a pushed screen covers this one (`RouteView` sets it).
    @Environment(\.screenIsTop) private var screenIsTop
    /// This screen is on screen. Pushed screens and sheet content report this
    /// through `onAppear`/`onDisappear`, so a screen underneath a pushed one
    /// does not reset its own scope when a presentation ends somewhere above it.
    @State private var visible = false

    init(active: Bool = true, @ViewBuilder content: () -> Content) {
        self.active = active
        self.content = content()
    }

    /// The one rule: the visible screen, on the top page, not covered by a push.
    private var mayOwnCrown: Bool { active && screenIsTop }

    var body: some View {
        content
            // The preference has to sit on the focusable view itself (the
            // scroll view), not on a wrapper around it.
            .prefersDefaultFocus(mayOwnCrown, in: scope)
            .focusScope(scope)
            // Coming back from a pushed screen: this screen is visible again, but
            // nothing told the focus system (Apple: "not when responding to
            // user-driven navigation commands").
            .onAppear {
                visible = true
                reevaluate()
            }
            .onDisappear { visible = false }
            .onChange(of: active) { _, _ in reevaluate() }
            // The deterministic half: `RouteView` says the screen above went away.
            .onChange(of: screenIsTop) { _, isTop in
                if isTop { reevaluate() }
            }
            .background { CrownFocusReclaim(scope: scope, enabled: mayOwnCrown && visible) }
    }

    private func reevaluate() {
        guard mayOwnCrown, visible else { return }
        resetFocus(in: scope)
    }
}

/// Reclaims the crown after the viewer / a sheet / a cover goes away. Its own
/// view so observing the signal never re-renders the screen's content.
private struct CrownFocusReclaim: View {
    let scope: Namespace.ID
    let enabled: Bool

    @Environment(\.resetFocus) private var resetFocus
    @ObservedObject private var mark = CrownFocusMark.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: mark.generation) { _, _ in
                if enabled { resetFocus(in: scope) }
            }
    }
}

extension View {
    func crownScrollFocus(active: Bool = true) -> some View {
        CrownScrollFocus(active: active) { self }
    }
}
