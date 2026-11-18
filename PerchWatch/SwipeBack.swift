import SwiftUI

/// iOS-like "swipe right to go back", but forgiving: the drag may start anywhere
/// on the screen (middle included), not only at the very left edge. Mostly
/// vertical drags are ignored, so scrolling and pull-to-refresh still work.
///
/// Guarded against the black-screen pop seen on the Watch:
/// - drags that start at the left edge are left to watchOS's own interactive
///   swipe-back; handling them too made two pops race in one transition and
///   could leave the navigation stack showing a black screen;
/// - one dismiss per appearance (a second `dismiss()` during the pop animation
///   could hit the screen underneath);
/// - the content offset is reset whenever the screen (re)appears or a pop does
///   not happen, so it can never stay shifted with black beside it.
struct SwipeBack: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var enabled = true

    /// Leading strip that belongs to the system's edge swipe.
    private static let systemEdge: CGFloat = 22

    @State private var offsetX: CGFloat = 0
    @State private var popping = false
    /// Live while the drag is; reset by SwiftUI on end *or cancel* (see `onChange`).
    @GestureState private var dragLive = false

    func body(content: Content) -> some View {
        content
            .offset(x: offsetX)
            .simultaneousGesture(
                DragGesture(minimumDistance: 25)
                    .updating($dragLive) { _, live, _ in live = true }
                    .onChanged { value in
                        let dx = value.translation.width
                        let horizontal = dx > 0 && abs(dx) > abs(value.translation.height) * 1.8
                        // Every rightward swipe guards the taps under it, including one
                        // that starts on the edge and is popped by the system.
                        if horizontal { SwipeGuard.begin() } else { SwipeGuard.end() }
                        guard enabled, !popping, value.startLocation.x > Self.systemEdge else { return }
                        guard horizontal else {
                            if offsetX != 0 { offsetX = 0 }
                            return
                        }
                        offsetX = min(dx, 120)
                    }
                    .onEnded { value in
                        SwipeGuard.end()
                        guard enabled, !popping, value.startLocation.x > Self.systemEdge else {
                            settle()
                            return
                        }
                        let dx = value.translation.width
                        let go = dx > 55 && abs(dx) > abs(value.translation.height) * 1.8
                        if go {
                            popping = true
                            // Back to rest first: the pop animates the whole
                            // screen away; a half-shifted screen is what showed
                            // black beside it when the pop did not complete.
                            withAnimation(.easeOut(duration: 0.12)) { offsetX = 0 }
                            dismiss()
                            // Still here after the pop should have finished (the
                            // system cancelled it): accept swipes again.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { popping = false }
                        } else {
                            settle()
                        }
                    }
            )
            .onChange(of: dragLive) { _, live in
                // Cancelled without `onEnded` (wrist down…): release taps, settle back.
                guard !live else { return }
                DispatchQueue.main.async {
                    SwipeGuard.end()
                    if !popping { settle() }
                }
            }
            .onAppear {
                offsetX = 0
                popping = false
            }
            .onDisappear { offsetX = 0 }
    }

    private func settle() {
        guard offsetX != 0 else { return }
        withAnimation(.easeOut(duration: 0.2)) { offsetX = 0 }
    }
}

extension View {
    func swipeBack(enabled: Bool = true) -> some View {
        modifier(SwipeBack(enabled: enabled))
    }
}
