import SwiftUI

/// iOS-like "swipe right to go back", but forgiving: the drag may start anywhere
/// on the screen (middle included), not only at the very left edge. Only clearly
/// horizontal drags count (3:1), so a diagonal scroll flick never turns into one.
///
/// The live offset is a `GestureState` (the whole pushed screen — a ScrollView and
/// its LazyVStack — is offset every frame, so writing `@State` per frame added a
/// layout pass on top of the gesture); `offsetX` is only the settled value used to
/// animate a cancelled swipe back.
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
    /// Set by `RouteView` on pushed screens: pops by state. Sheets have none and
    /// fall back to `dismiss()`.
    @Environment(\.popScreen) private var popScreen
    var enabled = true

    /// Leading strip that belongs to the system's edge swipe.
    private static let systemEdge: CGFloat = 22

    /// The settled offset (0 except for the frame that starts a settle animation).
    @State private var offsetX: CGFloat = 0
    /// The live drag: a gesture state, so the frame-by-frame movement does not
    /// write `@State` (and re-lay out the screen through a transaction) each frame.
    @GestureState private var dragDX: CGFloat = 0
    /// Live while the drag is; reset by SwiftUI on end *or cancel* (see `onChange`).
    @GestureState private var dragLive = false

    func body(content: Content) -> some View {
        content
            .offset(x: offsetX + dragDX)
            .simultaneousGesture(
                DragGesture(minimumDistance: 25)
                    .updating($dragLive) { _, live, _ in live = true }
                    .updating($dragDX) { value, state, _ in
                        guard value.startLocation.x > Self.systemEdge,
                              let dx = horizontal(value) else { return }
                        state = dx
                    }
                    .onChanged { value in
                        // Guard the taps under the finger while a horizontal swipe is on.
                        if horizontal(value) != nil { SwipeGuard.begin() } else { SwipeGuard.end() }
                    }
                    .onEnded { value in
                        SwipeGuard.end()
                        let dx = horizontal(value) ?? 0
                        let fromContent = value.startLocation.x > Self.systemEdge
                        let go = fromContent && dx > 55
                        if go {
                            // A pushed screen pops by state: one mutation, so it cannot
                            // race the system's own pop. The pop animates the screen
                            // away from where the finger left it; snapping back to rest
                            // first read as a bounce.
                            offsetX = dx
                            if let popScreen {
                                popScreen()
                                // If the pop did not go through, never leave the screen
                                // shifted with black beside it.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { settle() }
                            } else {
                                // A sheet's dismissal does not carry the offset.
                                withAnimation(.easeOut(duration: 0.12)) { offsetX = 0 }
                                dismiss()
                            }
                        } else if fromContent, dx > 0 {
                            offsetX = dx
                            withAnimation(.easeOut(duration: 0.2)) { offsetX = 0 }
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
                    settle()
                }
            }
            .onAppear { offsetX = 0 }
            .onDisappear { offsetX = 0 }
    }

    /// The drag as a rightward offset, or nil when it is not a clear horizontal swipe.
    private func horizontal(_ value: DragGesture.Value) -> CGFloat? {
        guard enabled else { return nil }
        let dx = value.translation.width
        guard dx > 25, dx > abs(value.translation.height) * 3 else { return nil }
        return min(dx, 140)
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
