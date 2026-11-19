#if DEBUG
import Foundation
import SwiftUI

/// DEBUG-only Digital Crown probe (crown-lab, 2026-11-18).
///
/// A UI test cannot read a SwiftUI scroll view's offset, so this modifier
/// republishes it as the `accessibilityValue` of an invisible marker element:
///
///     probe.<name>   value: "y=-3.0 h=980 v=248 os=12.0 mx=4.0"
///
/// `y` is `ScrollGeometry.contentOffset.y` (the number the crown tests read), `h`
/// the content height and `v` the viewport height, so a "did not move" line can say
/// whether the list had any room to move at all (an empty Likes list cannot scroll,
/// and that must not be reported as "the crown was not routed").
///
/// `os`, `mx`, `fr` and `dip` are for the crown-refresh tests: `os` is the positive
/// overscroll travel since launch, `mx` the deepest single overscroll, `fr` the part
/// of `os` that started from the top (a fresh nudge, which is how a crown turn looks
/// compared to a finger drag), and `dip` how often the band unwound back to the top
/// (a finger stays pulled, the crown's does not). `os == 0` after turning the crown
/// at the top means it never rubber-bands there, so no threshold could ever fire.
///
/// Inert by construction: no `.focusable`, no `@FocusState`, no `.disabled`, no
/// gestures (`allowsHitTesting(false)` on the marker), and the marker lives in an
/// overlay, so it changes no layout — watchOS keeps routing the crown by itself.
struct CrownProbe: ViewModifier {
    let name: String

    /// Tracking state lives in a class, like `PullToRefresh`'s `OverscrollTracker`:
    /// a scroll frame must not re-render the scroll view it is measuring.
    @State private var box = CrownProbeBox()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CrownScrollState.self) { geo in
                CrownScrollState(offsetY: geo.contentOffset.y,
                                 contentHeight: geo.contentSize.height,
                                 viewportHeight: geo.containerSize.height,
                                 inset: geo.contentInsets.top)
            } action: { _, new in
                box.record(new)
            }
            .overlay(alignment: .topLeading) {
                CrownProbeMarker(name: name, box: box)
            }
    }
}

/// What the probe reports, rounded so a sub-point change does not republish.
struct CrownScrollState: Equatable {
    var offsetY: CGFloat
    var contentHeight: CGFloat
    var viewportHeight: CGFloat
    var inset: CGFloat

    /// Positive while pulled down past the top.
    var overscroll: CGFloat { max(0, -(offsetY + inset)) }
}

/// Holds the last reading; only the marker observes it.
final class CrownProbeBox: ObservableObject {
    @Published var text = "y=0.0 h=0 v=0 os=0.0 mx=0.0 fr=0.0 dip=0"
    private var last: CGFloat = 0
    private var travel: CGFloat = 0
    private var peak: CGFloat = 0
    private var fresh: CGFloat = 0
    private var dips = 0
    private var low: CGFloat = 0

    func record(_ s: CrownScrollState) {
        let os = s.overscroll
        if os > last {
            let delta = os - last
            travel += delta
            if last <= 2 { fresh += delta }
        } else if last > 2, os <= 2 {
            dips += 1
        }
        last = os
        peak = max(peak, os)
        low = min(low, os)
        text = String(format: "y=%.1f h=%.0f v=%.0f os=%.1f mx=%.1f mn=%.1f fr=%.1f dip=%d t=%@",
                      Double(s.offsetY), Double(s.contentHeight), Double(s.viewportHeight),
                      Double(travel), Double(peak), Double(low), Double(fresh), dips,
                      PerchTrace.refresh)
    }
}

/// A 1 pt, fully transparent glyph. A `Text` is always in the accessibility tree
/// (a `Color.clear` is not guaranteed to be), and at 1 pt with a clear foreground
/// it is invisible.
private struct CrownProbeMarker: View {
    let name: String
    @ObservedObject var box: CrownProbeBox

    var body: some View {
        Text(verbatim: "crown")
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityIdentifier("probe." + name)
            .accessibilityValue(Text(verbatim: box.text))
    }
}
#endif
