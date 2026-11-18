import SwiftUI

/// Gives the Digital Crown back to this screen's scroll view.
///
/// watchOS sends the crown to the focused view. Two things used to leave it
/// pointing nowhere, so the crown did nothing until the screen was touched:
/// - the media viewer's pages are `.focusable()` (crown zoom / volume); when the
///   viewer closed, focus did not return to the feed underneath;
/// - swiping the root pager to another feed left focus on the page that had
///   just scrolled off screen;
/// - popping a pushed screen (post, profile…) left the crown with the screen
///   that had gone, while this screen's FocusState still read `true`.
/// Apply it directly to the `ScrollView`/`List` (not to a wrapper such as
/// `.background`), so the binding lands on the focusable view itself.
/// This binds the scroll view to a `@FocusState` and claims it whenever the
/// screen becomes the visible one: on appear (including coming back from a
/// pushed screen), when its pager page becomes active, and when the media
/// viewer closes.
struct CrownScrollFocus: ViewModifier {
    /// False for a pager page that is off screen.
    var active: Bool = true

    @FocusState private var focused: Bool
    @State private var visible = false
    @ObservedObject private var presenter = MediaPresenter.shared

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onAppear {
                visible = true
                claim()
            }
            .onDisappear { visible = false }
            .onChange(of: active) { _, isActive in
                if isActive { claim() }
            }
            .onChange(of: presenter.target == nil) { _, closed in
                if closed { claim() }
            }
    }

    private var canClaim: Bool { active && visible && presenter.target == nil }

    private func claim() {
        // Wait for the view that held focus (viewer, previous page, popped
        // screen) to finish leaving; focusing during its removal animation
        // does not stick. Twice: the second attempt covers a slow animation.
        for delay in [0.3, 0.8] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard canClaim else { return }
                // Always re-assert, never `if !focused`: after a pushed screen
                // (a post) took the crown and was popped, this FocusState still
                // read `true` although the focus engine had moved on, so the
                // feed never asked for the crown back and it did nothing until
                // the screen was touched. Clearing it first makes the next
                // assignment a real focus request.
                focused = false
                DispatchQueue.main.async {
                    if canClaim { focused = true }
                }
            }
        }
    }
}

extension View {
    func crownScrollFocus(active: Bool = true) -> some View {
        modifier(CrownScrollFocus(active: active))
    }
}
