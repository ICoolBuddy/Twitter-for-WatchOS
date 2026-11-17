import SwiftUI

/// Gives the Digital Crown back to this screen's scroll view.
///
/// watchOS sends the crown to the focused view. Two things used to leave it
/// pointing nowhere, so the crown did nothing until the screen was touched:
/// - the media viewer's pages are `.focusable()` (crown zoom / volume); when the
///   viewer closed, focus did not return to the feed underneath;
/// - swiping the root pager to another feed left focus on the page that had
///   just scrolled off screen.
/// This binds the scroll view to a `@FocusState` and claims it whenever the
/// screen becomes the visible one: on appear, when its pager page becomes
/// active, and when the media viewer closes.
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

    private func claim() {
        // Wait for the view that held focus (viewer, previous page) to finish
        // leaving; focusing during its removal animation does not stick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard active, visible, presenter.target == nil else { return }
            focused = true
        }
    }
}

extension View {
    func crownScrollFocus(active: Bool = true) -> some View {
        modifier(CrownScrollFocus(active: active))
    }
}
