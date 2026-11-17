import SwiftUI

/// Pull-to-refresh for watchOS scroll views. watchOS accepts `.refreshable` but
/// draws no control for it, so this tracks the scroll view's overscroll at the
/// top: the status bar fills as you pull, and crossing the threshold starts the
/// refresh. Turning the Digital Crown at the top rubber-bands by only a few
/// points per detent, so those small increases are accumulated too — rotating
/// the crown a lot refreshes as well.
///
/// The visible bar lives in `FeedStatusBar` (HomeView); this only reports
/// progress and triggers the action. No haptics (refreshing must be silent).
struct PullToRefresh: ViewModifier {
    let isRefreshing: Bool
    /// 0…1 — how close the reader is to a refresh (finger pull or crown travel).
    var progress: Binding<CGFloat>?
    let action: () async -> Void

    /// A full finger pull (points of overscroll).
    static let threshold: CGFloat = 48
    /// Total crown rubber-band travel that counts as "rotated a lot".
    static let crownThreshold: CGFloat = 90

    @State private var pull: CGFloat = 0
    @State private var crown: CGFloat = 0
    /// Re-armed once the content has settled back near the top, so one pull = one refresh.
    @State private var armed = true
    /// Reference box: keeping the previous offset in a class means tracking it
    /// does not re-render the scroll view on every frame.
    @State private var tracker = OverscrollTracker()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                // Positive while the content is dragged down past its top edge.
                -(geo.contentOffset.y + geo.contentInsets.top)
            } action: { _, overscroll in
                update(overscroll)
            }
            // Never leave the bar half full: clear it when the refresh starts
            // (the loading bar takes over) and when it ends.
            .onChange(of: isRefreshing) { _, refreshing in
                if pull != 0 { pull = 0 }
                tracker.last = 0
                if refreshing {
                    if crown != 0 { crown = 0 }
                    if armed { armed = false }
                }
                report()
            }
    }

    private func update(_ overscroll: CGFloat) {
        let value = max(0, overscroll)
        if value != pull { pull = value }

        if overscroll > 0 {
            // Each upward nudge at the top adds to the running total, so many
            // small crown rubber-bands can add up to a full pull.
            let delta = overscroll - tracker.last
            if delta > 0, crown < Self.crownThreshold {
                crown = min(Self.crownThreshold, crown + delta)
            }
        } else if overscroll < -20, crown != 0 {
            // Really scrolled away: start counting from zero again.
            crown = 0
        }
        tracker.last = overscroll

        if overscroll < 6, !armed { armed = true }
        let ready = overscroll >= Self.threshold || crown >= Self.crownThreshold
        let sinceTrigger = Date().timeIntervalSince(tracker.triggered)
        if armed, !isRefreshing, ready, sinceTrigger > 1 {
            armed = false
            tracker.triggered = Date()
            if crown != 0 { crown = 0 }
            Task { await action() }
        }
        report()
    }

    private func report() {
        guard let progress else { return }
        let p = min(1, max(pull / Self.threshold, crown / Self.crownThreshold))
        if abs(progress.wrappedValue - p) > 0.01 { progress.wrappedValue = p }
    }
}

/// Mutable box so per-frame tracker state does not invalidate SwiftUI views.
private final class OverscrollTracker {
    var last: CGFloat = 0
    var triggered = Date.distantPast
}

extension View {
    func pullToRefresh(isRefreshing: Bool, progress: Binding<CGFloat>? = nil,
                       action: @escaping () async -> Void) -> some View {
        modifier(PullToRefresh(isRefreshing: isRefreshing, progress: progress, action: action))
    }
}
