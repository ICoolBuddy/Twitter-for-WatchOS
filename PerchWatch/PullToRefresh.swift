import SwiftUI
import XKit

/// Pull-to-refresh for watchOS scroll views. watchOS accepts `.refreshable` but
/// draws no control for it, so this tracks the scroll view's overscroll at the
/// top: the status pill appears while the fetch runs, and crossing the threshold
/// starts the refresh. Turning the Digital Crown at the top rubber-bands by only
/// a few points per detent, so those small increases are accumulated too —
/// rotating the crown a lot refreshes as well.
///
/// The tracker lives in a class, so following the overscroll never re-renders the
/// scroll view.
struct PullToRefresh: ViewModifier {
    let isRefreshing: Bool
    /// The last refresh failed: the pill says so instead of "Updated".
    var failed = false
    /// Off for screens that show their own fetch status; the feeds keep both the
    /// edge glow and this pill.
    var showsIndicator = true
    let action: () async -> Void

    /// A full finger pull (points of overscroll).
    static let threshold: CGFloat = 48
    /// Total crown rubber-band travel that counts as "rotated a lot".
    static let crownThreshold: CGFloat = 90

    /// Reference box: all per-frame tracking state lives in a class.
    @State private var tracker = OverscrollTracker()

    func body(content: Content) -> some View {
        content
            // A toast at the bottom: the top belongs to the clock and the title,
            // and a pill there covered them (and the pull itself).
            .overlay(alignment: .bottom) {
                if showsIndicator {
                    RefreshStatus(isRefreshing: isRefreshing, failed: failed)
                        .padding(.bottom, 4)
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

/// The fetch, said out loud: what is happening and how fast the link is going,
/// then a short "Updated" so the end of a refresh is visible without a jump.
struct RefreshStatus: View {
    var isRefreshing: Bool
    var failed = false

    @State private var finished = false
    /// The outcome of the refresh that just ended, so the tail says the truth.
    @State private var lastFailed = false
    @State private var finishTask: Task<Void, Never>?

    private static let appear = Animation.spring(response: 0.32, dampingFraction: 0.86)

    var body: some View {
        // A ZStack (not a bare `if`) so the observer below stays alive while the
        // pill is hidden — otherwise it could never notice the refresh ending.
        ZStack(alignment: .bottom) {
            if isRefreshing || finished {
                pill
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
        .onChange(of: isRefreshing) { _, refreshing in
            finishTask?.cancel()
            if refreshing {
                withAnimation(Self.appear) { finished = false }
            } else {
                lastFailed = failed
                withAnimation(Self.appear) { finished = true }
                finishTask = Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.25)) { finished = false }
                }
            }
        }
    }

    private var pill: some View {
        HStack(spacing: 4) {
            if isRefreshing {
                Text("Refreshing")
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let rate = TransferMonitor.shared.snapshot().bytesPerSecond
                    // Sub-kilobyte traffic is mostly headers: say nothing.
                    if rate >= 500 {
                        Text("· " + TransferMonitor.formatRate(rate))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            } else if lastFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.orange)
                Text("Couldn't update")
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.green)
                Text("Updated")
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        // The app's own pill look (viewer counter, volume HUD): a flat black
        // capsule, no material — the system spinner that came with a material
        // background was a big grey disc on watchOS.
        .background(Color.black.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
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
    func pullToRefresh(isRefreshing: Bool, failed: Bool = false, showsIndicator: Bool = true,
                       action: @escaping () async -> Void) -> some View {
        modifier(PullToRefresh(isRefreshing: isRefreshing, failed: failed,
                               showsIndicator: showsIndicator, action: action))
    }
}
