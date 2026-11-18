import SwiftUI

/// "A presentation that owned the crown has finished going away." One signal for
/// the media viewer (root host, sheet host and cover), the profile sheet and the
/// account picker, so the screen behind them can take the crown back the same
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

/// Gives the Digital Crown back to this screen's scroll view.
///
/// watchOS sends the crown to the focused view, and a touch is what normally
/// makes the scroll view the target. What the system does *not* do is re-run that
/// decision when a screen comes back from a pushed screen, when the media viewer
/// goes away or when a pager page slides in (Apple: default focus is evaluated
/// "when the window first appears, and when a focus state binding update moves
/// focus automatically, but not when responding to user-driven navigation
/// commands"), so without this the crown does nothing until the screen is
/// touched.
///
/// The *ownership* half is a value, not a guess: only the visible screen (`active`),
/// on top of the stack (`screenIsTop`), with no viewer over it, may ask. The
/// *request* half still has to be an explicit focus assignment — a focus scope
/// with `prefersDefaultFocus` + `resetFocus(in:)` is documented, but on
/// watchOS 27 it does not give a scroll view the crown (tried and failed on the
/// Series 10: cold start and after the pager's own buttons).
struct CrownScrollFocus: ViewModifier {
    /// False for a pager page that is off screen.
    var active: Bool = true

    @Environment(\.screenIsTop) private var screenIsTop
    @FocusState private var focused: Bool
    @ObservedObject private var presenter = MediaPresenter.shared
    @State private var visible = false
    /// Live values for the asynchronous requests: this is a value type, so a
    /// delayed closure would otherwise read the flags it was created with — the
    /// stale `active` that made an off-screen page steal the crown.
    @State private var claim = CrownClaim()

    private var ownsCrown: Bool {
        active && screenIsTop && visible
            && presenter.target == nil && !presenter.isTransitioning
    }

    func body(content: Content) -> some View {
        // Read on every pass, so a delayed request sees the truth.
        claim.allowed = ownsCrown
        return content
            .focused($focused)
            .onAppear {
                visible = true
                apply()
            }
            .onDisappear {
                visible = false
                focused = false
            }
            .onChange(of: ownsCrown) { _, _ in apply() }
            // A sheet just closed over this screen: same ownership, but the
            // system moved focus to the sheet and did not bring it back.
            .background { CrownFocusReclaim(enabled: true) { apply() } }
    }

    private func apply() {
        guard ownsCrown else {
            focused = false
            return
        }
        request(attempt: 0)
    }

    /// Release, then request: after another screen owned the crown this binding
    /// can still read `true` while the engine's focus is gone (fd4cbc3), so
    /// assigning `true` again would not be a change. The retries cover the
    /// system's own animations (a pop, the viewer's removal), which we cannot
    /// observe; every one of them is skipped the moment this screen stops owning
    /// the crown, so they can never steal it from a screen opened in between.
    private func request(attempt: Int) {
        guard claim.allowed else { return }
        focused = false
        DispatchQueue.main.async {
            guard claim.allowed else { return }
            focused = true
            let waits: [Double] = [0.3, 0.9]
            guard attempt < waits.count else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + waits[attempt]) {
                guard claim.allowed else { return }
                request(attempt: attempt + 1)
            }
        }
    }
}

/// Mutable box for the ownership flag (never part of the view's state).
private final class CrownClaim {
    var allowed = false
}

/// Takes the crown back after a presentation goes away. Its own view so observing
/// the signal never re-renders the screen's content.
private struct CrownFocusReclaim: View {
    let enabled: Bool
    let action: () -> Void

    @ObservedObject private var mark = CrownFocusMark.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: mark.generation) { _, _ in
                if enabled { action() }
            }
    }
}

extension View {
    func crownScrollFocus(active: Bool = true) -> some View {
        modifier(CrownScrollFocus(active: active))
    }
}
