import SwiftUI

/// iOS-like "swipe right to go back", but forgiving: the drag may start anywhere
/// on the screen (middle included), not only at the very left edge. Mostly
/// vertical drags are ignored, so scrolling and pull-to-refresh still work.
struct SwipeBack: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    var enabled = true

    @State private var offsetX: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offsetX)
            .simultaneousGesture(
                DragGesture(minimumDistance: 25)
                    .onChanged { value in
                        guard enabled else { return }
                        let dx = value.translation.width
                        guard dx > 0, abs(dx) > abs(value.translation.height) * 1.8 else { return }
                        offsetX = min(dx, 120)
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let go = enabled && dx > 55
                            && abs(dx) > abs(value.translation.height) * 1.8
                        withAnimation(.easeOut(duration: 0.2)) { offsetX = 0 }
                        if go { dismiss() }
                    }
            )
    }
}

extension View {
    func swipeBack(enabled: Bool = true) -> some View {
        modifier(SwipeBack(enabled: enabled))
    }
}
