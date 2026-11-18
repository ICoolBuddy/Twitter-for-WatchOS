import SwiftUI

/// Remembers when a horizontal swipe (root pager, swipe-back) last moved, so a
/// control under the finger does not also fire when the finger lifts. The swipe
/// gestures are `simultaneousGesture`s (exclusive ones would break vertical
/// scrolling), so the button, link or text field link under the finger still
/// gets the touch: lifting it over an image opened the viewer *and* paged.
/// Taps within a short window of swipe movement are ignored.
///
/// Only the Watch's gestures mark it; on the iPhone it is never active.
/// Gesture callbacks and button actions all run on the main thread, so the
/// unsynchronised storage is safe; it is nonisolated so button styles (whose
/// isolation differs between SDKs) can read it.
enum SwipeGuard {
    nonisolated(unsafe) private static var lastMove = Date.distantPast

    /// Called on every movement of a recognised horizontal swipe, and when it ends.
    static func mark() { lastMove = Date() }

    /// A horizontal swipe is in progress or just ended.
    static var isActive: Bool { Date().timeIntervalSince(lastMove) < 0.35 }
}

/// Plain-looking button style that drops the tap when it ends a horizontal
/// swipe. A `PrimitiveButtonStyle` styles every button-like control, so the same
/// style covers `Button`, `NavigationLink` and `TextFieldLink`:
/// `configuration.trigger()` is what runs the action, pushes the link or opens
/// the text input.
///
/// - `.swipeSafe`: drop-in for `.plain` (the label keeps its own size/shape).
/// - `.swipeSafeRow`: for list rows; the whole row width is tappable, as with
///   the system row style.
struct SwipeSafeButtonStyle: PrimitiveButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            guard !SwipeGuard.isActive else { return }
            configuration.trigger()
        } label: {
            if fullWidth {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            } else {
                configuration.label
            }
        }
        .buttonStyle(.plain)
    }
}

extension PrimitiveButtonStyle where Self == SwipeSafeButtonStyle {
    static var swipeSafe: SwipeSafeButtonStyle { SwipeSafeButtonStyle() }
    static var swipeSafeRow: SwipeSafeButtonStyle { SwipeSafeButtonStyle(fullWidth: true) }
}
