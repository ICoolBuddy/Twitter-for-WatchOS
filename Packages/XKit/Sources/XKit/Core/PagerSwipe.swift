import Foundation

/// The root pager's swipe rule, as pure maths (no SwiftUI) so it is unit-tested.
///
/// A page swipe must declare itself early (the axis is decided within `axisWindow`),
/// an early horizontal call is revoked once the drag is unambiguously vertical, and a
/// page turn needs a real horizontal drag of 35 % of the width that is still horizontal
/// at release — or a short, fast, clean throw. Before, one horizontal-looking frame
/// latched the swipe for the whole gesture and the commit used only the velocity
/// prediction, so a vertical scroll with a thumb arc could open the menu.
public enum PagerSwipe {
    public static let axisWindow = 30.0
    public static let verticalTravel = 20.0
    public static let verticalRatio = 0.8      // within ~39° of vertical: a scroll
    public static let horizontalRatio = 1.5    // within ~34° of horizontal: a page swipe
    public static let revokeTravel = 40.0
    public static let revokeRatio = 0.5        // within ~27° of vertical after 40 pt: revoke
    public static let dragDistance = 0.35      // × width, actual finger travel
    public static let dragRatio = 1.0          // still more horizontal than vertical at release
    public static let flickDistance = 0.12     // × width
    public static let flickPredicted = 0.55    // × width, predicted travel of a real throw
    public static let flickRatio = 1.5

    public enum Axis: Equatable, Sendable { case horizontal, vertical }

    /// The axis for this frame, from the cumulative translation. Decided once, except
    /// that a wrong horizontal call is revoked when the drag becomes clearly vertical.
    public static func axis(decided: Axis?, dx: Double, dy: Double) -> Axis? {
        if decided == .horizontal, abs(dy) >= revokeTravel, abs(dx) < abs(dy) * revokeRatio {
            return .vertical
        }
        if let decided { return decided }
        if abs(dy) >= verticalTravel, abs(dx) < abs(dy) * verticalRatio { return .vertical }
        if abs(dx) > abs(dy) * horizontalRatio { return .horizontal }
        // Undecided after the window: the finger is not making a page swipe.
        if abs(dx) > axisWindow || abs(dy) > axisWindow { return .vertical }
        return nil
    }

    /// Where a released horizontal drag settles. `page` is 0 (menu) … `lastPage`.
    public static func target(page: Int, lastPage: Int = 2, width w: Double, dx: Double, dy: Double,
                              predicted: Double) -> Int {
        guard w > 0, dx != 0 else { return page }
        // Never commit a throw that is being pulled back.
        guard predicted == 0 || (predicted > 0) == (dx > 0) else { return page }
        let dragged = abs(dx) >= w * dragDistance && abs(dx) >= abs(dy) * dragRatio
        let flicked = abs(dx) >= w * flickDistance
            && abs(dx) >= abs(dy) * flickRatio
            && abs(predicted) >= w * flickPredicted
        guard dragged || flicked else { return page }
        // Right is towards the menu (page 0), left towards the last page.
        return min(max(page + (dx > 0 ? -1 : 1), 0), lastPage)
    }
}
