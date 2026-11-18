import SwiftUI

/// Whether the touch that is ending is a horizontal swipe (root pager, swipe-back), so
/// the control under the finger does not also fire. The swipe gestures are
/// `simultaneousGesture`s (exclusive ones would break vertical scrolling), so the
/// button, link or text field link under the finger still gets the touch.
///
/// It follows the swipe's lifetime instead of a clock: `begin()` when a horizontal swipe
/// is recognised, `end()` when it ends or is cancelled. A short tail after the lift
/// covers the tap that belongs to the same lift (the control's action and the drag's
/// end arrive in either order). A new tap needs a new touch-down and lift, which takes
/// longer than the tail, so a quick tap right after paging works (the old 0.35 s window
/// swallowed it).
///
/// Only the Watch's gestures drive it; on the iPhone it is never active.
/// Gesture callbacks and button actions all run on the main thread, so the
/// unsynchronised storage is safe; it is nonisolated so button styles (whose isolation
/// differs between SDKs) can read it. Monotonic clock: a wall-clock change can't wedge it.
enum SwipeGuard {
    nonisolated(unsafe) private static var swiping = false
    nonisolated(unsafe) private static var liftedAt: UInt64 = 0
    private static let liftTail: UInt64 = 80_000_000      // 80 ms, in nanoseconds

    /// A horizontal swipe is under the finger (idempotent; call on every movement).
    static func begin() { swiping = true }

    /// The swipe ended or was cancelled.
    static func end() {
        guard swiping else { return }
        swiping = false
        liftedAt = DispatchTime.now().uptimeNanoseconds
    }

    /// The touch that is ending belongs to a swipe.
    static var isActive: Bool {
        swiping || DispatchTime.now().uptimeNanoseconds &- liftedAt < liftTail
    }

    /// For controls that keep a system style (bordered, toolbar) and so cannot use
    /// `.buttonStyle(.swipeSafe)`: wraps the action once, no guard at each call site.
    @MainActor
    static func run(_ action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        { if !isActive { action() } }
    }
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
