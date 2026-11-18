import SwiftUI

/// Pull-to-refresh for watchOS scroll views. watchOS accepts `.refreshable` but
/// draws no control for it, so this tracks the scroll view's overscroll at the
/// top: the status bar fills as you pull, and crossing the threshold starts the
/// refresh. Turning the Digital Crown at the top rubber-bands by only a few
/// points per detent, so those small increases are accumulated too — rotating
/// the crown a lot refreshes as well.
///
/// This only triggers the action; there is no pull indicator. The edge glow
/// (`EdgeGlow`, HomeView) shows the fetch itself. No haptics (refreshing must
/// be silent).
struct PullToRefresh: ViewModifier {
    let isRefreshing: Bool
    /// The home feeds have their own indicators (edge glow, placeholder post).
    var showsIndicator = true
    let action: () async -> Void

    /// A full finger pull (points of overscroll).
    static let threshold: CGFloat = 48
    /// Total crown rubber-band travel that counts as "rotated a lot".
    static let crownThreshold: CGFloat = 90

    /// Reference box: all per-frame tracking state lives in a class, so
    /// following the overscroll never re-renders the scroll view.
    @State private var tracker = OverscrollTracker()

    func body(content: Content) -> some View {
        content
            // The refresh itself is the indicator (pushed lists have no edge glow):
            // derived from `isRefreshing`, not from the pull.
            .overlay(alignment: .top) {
                if isRefreshing, showsIndicator {
                    HStack(spacing: 5) {
                        ProgressView()
                        Text("Refreshing…").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                // Positive while the content is dragged down past its top edge.
                -(geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, overscroll in
                update(overscroll)
            }
            // A refresh that starts (from here or elsewhere) consumes the
            // gesture: the reader must return to the top before the next one.
            .onChange(of: isRefreshing) { _, refreshing in
                tracker.last = 0
                if refreshing {
                    tracker.crown = 0
                    tracker.armed = false
                }
            }
    }

    private func update(_ overscroll: CGFloat) {
        let t = tracker
        if overscroll > 0 {
            // Each upward nudge at the top adds to the running total, so many
            // small crown rubber-bands can add up to a full pull.
            let delta = overscroll - t.last
            if delta > 0 { t.crown = min(Self.crownThreshold, t.crown + delta) }
        } else if overscroll < -20 {
            // Really scrolled away: start counting from zero again.
            t.crown = 0
        }
        t.last = overscroll

        if overscroll < 6 { t.armed = true }
        let ready = overscroll >= Self.threshold || t.crown >= Self.crownThreshold
        // `armed` (one pull per gesture) and `isRefreshing` (nothing to trigger while a
        // refresh runs) are the whole rule.
        if t.armed, !isRefreshing, ready {
            t.armed = false
            t.crown = 0
            Task { await action() }
        }
    }
}

/// Mutable box so per-frame tracker state does not invalidate SwiftUI views.
private final class OverscrollTracker {
    var last: CGFloat = 0
    /// Accumulated crown rubber-band travel at the top.
    var crown: CGFloat = 0
    /// Re-armed once the content is back near the top: one pull = one refresh.
    var armed = true
}

extension View {
    func pullToRefresh(isRefreshing: Bool, showsIndicator: Bool = true,
                       action: @escaping () async -> Void) -> some View {
        modifier(PullToRefresh(isRefreshing: isRefreshing, showsIndicator: showsIndicator, action: action))
    }
}
