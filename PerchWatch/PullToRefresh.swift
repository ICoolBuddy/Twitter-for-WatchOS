import SwiftUI
import WatchKit
import XKit

/// Pull-to-refresh for watchOS scroll views (watchOS accepts `.refreshable` but
/// draws nothing). Like iOS: pull past the threshold (a stretchy arrow grows, flips
/// up with a haptic when it is far enough) and the refresh starts when you *let go*,
/// not the moment the threshold is crossed. Turning the Digital Crown at the top
/// rubber-bands a few points per detent; those add up the same way and the refresh
/// starts when the crown stops.
///
/// "Let go" is the scroll phase leaving `.interacting` (watchOS 11 `onScrollPhaseChange`),
/// so there is no timer. Per-frame tracking lives in a class; only the small
/// indicator observes the pull progress, never the scroll view.
struct PullToRefresh: ViewModifier {
    let isRefreshing: Bool
    /// The last refresh failed: the pill says so instead of "Updated".
    var failed = false
    /// Off for screens that show their own fetch status; the feeds keep both the
    /// edge glow and this pill.
    var showsIndicator = true
    let action: () async -> Void

    /// A full finger pull (points of overscroll).
    static let threshold: CGFloat = 52
    /// Total crown rubber-band travel that counts as a full pull.
    static let crownThreshold: CGFloat = 90

    @State private var tracker = OverscrollTracker()
    @State private var pull = PullState()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                PullIndicator(state: pull, isRefreshing: isRefreshing)
                    .allowsHitTesting(false)
            }
            // A toast at the bottom: the top belongs to the clock and the title.
            .overlay(alignment: .bottom) {
                if showsIndicator {
                    RefreshStatus(isRefreshing: isRefreshing, failed: failed)
                        .padding(.bottom, 4)
                        .allowsHitTesting(false)
                }
            }
            .onScrollGeometryChange(for: CGSize.self) { geo in
                // width: overscroll (positive while dragged down past the top);
                // height: the top inset, where the indicator sits.
                CGSize(width: -(geo.contentOffset.y + geo.contentInsets.top),
                       height: geo.contentInsets.top)
            } action: { _, g in
                pull.topInset = g.height
                update(g.width)
            }
            .onScrollPhaseChange { _, phase in
                tracker.interacting = phase == .interacting
                // Released (finger up / crown stopped) while the arrow pointed up.
                if phase != .interacting, tracker.ready {
                    fire()
                }
            }
            // A refresh that starts (from here or elsewhere) consumes the gesture.
            .onChange(of: isRefreshing) { _, refreshing in
                tracker.last = 0
                if refreshing {
                    tracker.crown = 0
                    setReady(false)
                }
            }
    }

    private func update(_ overscroll: CGFloat) {
        let t = tracker
        if overscroll > 0 {
            // Each upward nudge at the top adds up, so crown rubber-bands count too.
            let delta = overscroll - t.last
            if delta > 0, !t.interacting { t.crown = min(Self.crownThreshold, t.crown + delta) }
        } else if overscroll < -20 {
            t.crown = 0
        }
        t.last = overscroll
        guard !isRefreshing else { return }

        let finger = max(0, overscroll) / Self.threshold
        let crown = t.crown / Self.crownThreshold
        let progress = min(1, max(finger, crown))
        pull.setProgress(progress)
        if progress >= 1 {
            setReady(true)
        } else if t.interacting, finger < 0.7, crown < 1 {
            // Pushed back up before letting go: no refresh (the arrow turns back).
            setReady(false)
        }
    }

    private func setReady(_ ready: Bool) {
        guard tracker.ready != ready else { return }
        tracker.ready = ready
        if ready { WKInterfaceDevice.current().play(.click) }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pull.ready = ready }
    }

    private func fire() {
        guard !isRefreshing else { return }
        tracker.crown = 0
        setReady(false)
        pull.setProgress(0)
        Task { await action() }
    }
}

/// What the indicator draws; the only observable part of the pull.
final class PullState: ObservableObject {
    /// 0…1 of a full pull.
    @Published private(set) var progress: CGFloat = 0
    /// Past the threshold: letting go refreshes.
    @Published var ready = false
    var topInset: CGFloat = 0

    func setProgress(_ value: CGFloat) {
        // A frame-by-frame value: publish only visible changes.
        if abs(value - progress) > 0.02 || (value == 0 && progress != 0) || (value == 1 && progress != 1) {
            progress = value
        }
    }
}

/// The stretchy arrow: grows with the pull, flips up when letting go will refresh,
/// becomes a spinning arc while the refresh runs.
private struct PullIndicator: View {
    @ObservedObject var state: PullState
    let isRefreshing: Bool

    var body: some View {
        ZStack {
            if isRefreshing {
                Spinner()
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if state.progress > 0.05 {
                arrow
                    .transition(.opacity)
            }
        }
        .frame(width: 24, height: 40)
        .padding(.top, state.topInset + 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isRefreshing)
        .accessibilityHidden(true)
    }

    private var arrow: some View {
        let p = state.progress
        return VStack(spacing: 0) {
            // The shaft stretches with the pull; the head stays the same size.
            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: 4 + 14 * p)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .offset(y: -3)
        }
        .foregroundStyle(.white)
        .rotationEffect(.degrees(state.ready ? 180 : 0))
        .scaleEffect(0.7 + 0.3 * p)
        .opacity(Double(min(1, p * 1.4)))
    }
}

/// A thin white arc that spins (watchOS draws `ProgressView` as a grey disc here).
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
                .frame(width: 16, height: 16)
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
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
    /// Past the threshold: the release (phase leaving `.interacting`) refreshes.
    var ready = false
    /// A finger is on the scroll view.
    var interacting = false
}

extension View {
    func pullToRefresh(isRefreshing: Bool, failed: Bool = false, showsIndicator: Bool = true,
                       action: @escaping () async -> Void) -> some View {
        modifier(PullToRefresh(isRefreshing: isRefreshing, failed: failed,
                               showsIndicator: showsIndicator, action: action))
    }
}
