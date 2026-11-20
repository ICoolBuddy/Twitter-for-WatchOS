import SwiftUI
import WatchKit
import XKit

/// Pull-to-refresh for watchOS scroll views (watchOS accepts `.refreshable` but
/// draws nothing). Like iOS: pull past the threshold (a stretchy arrow grows down
/// from under the clock into the gap the pull opens, flips up with a haptic when
/// it is far enough) and the refresh starts when you *let go*, not the moment the
/// threshold is crossed.
///
/// The Digital Crown is the primary input on the Watch, so it gets its own path:
/// turning it up at the top rubber-bands a few points per detent, those add up,
/// and the refresh starts as soon as there is enough travel — no "release" wait
/// (watchOS never reports one for the crown) and a much shorter travel than a
/// finger needs. If the crown stops short, the arrow clears itself after a moment
/// instead of sitting on screen until the next scroll.
///
/// The indicator lives at the very top, in the empty space the pull opens (not a
/// floating pill in the middle of the screen), and is removed the moment a
/// refresh ends; only a short "Updated" line stays.
struct PullToRefresh: ViewModifier {
    let isRefreshing: Bool
    /// The last refresh failed: the line says so instead of "Updated".
    var failed = false
    /// Off for screens that show their own fetch status: the spinner stays, the
    /// status text is skipped.
    var showsIndicator = true
    let action: () async -> Void

    /// A full finger pull (points of overscroll).
    static let threshold: CGFloat = 44
    /// Crown rubber-band travel that counts as a full pull. A detent at the top is
    /// a few points, so this is a handful of turns, not thirty.
    static let crownThreshold: CGFloat = 20
    /// The crown's rubber band unwinds by itself; if it stops short of the
    /// threshold, forget the partial pull instead of leaving the arrow up.
    static let crownIdle: UInt64 = 900_000_000

    @State private var tracker = OverscrollTracker()
    @State private var pull = PullState()
    @State private var idleTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                PullIndicator(state: pull, isRefreshing: isRefreshing,
                              failed: failed, showsStatus: showsIndicator)
                    .allowsHitTesting(false)
            }
            .onScrollGeometryChange(for: CGSize.self) { geo in
                // width: overscroll (positive while dragged down past the top);
                // height: the top inset, where the toolbar and clock are.
                CGSize(width: -(geo.contentOffset.y + geo.contentInsets.top),
                       height: geo.contentInsets.top)
            } action: { _, g in
                pull.topInset = g.height
                update(g.width)
            }
            .onScrollPhaseChange { _, phase in
                tracker.interacting = phase == .interacting
                // Do NOT zero the crown travel here: watchOS reports a crown turn as
                // `.interacting` too, and this reset (once per turn) is why ten turns
                // never added up (trace: 271 pt seen, counter stuck at 4).
                // Released (finger up) while the arrow pointed up.
                if phase != .interacting, tracker.ready { fire() }
            }
            .onChange(of: isRefreshing) { _, refreshing in
                idleTask?.cancel()
                tracker.last = 0
                // Keep the crown travel: a refresh from elsewhere (on open, account
                // switch, a retry) must not zero a pull the reader is still turning.
                tracker.ready = false
                pull.reset()
                // A refresh that starts consumes every leftover frame of the pull;
                // `fired` blocks stray geometry events until the list is back at 0.
                tracker.fired = refreshing
            }
    }

    private func update(_ overscroll: CGFloat) {
        let t = tracker
        #if DEBUG
        PerchTrace.updates += 1
        PerchTrace.maxCrown = max(PerchTrace.maxCrown, t.crown)
        PerchTrace.maxOverscroll = max(PerchTrace.maxOverscroll, overscroll)
        PerchTrace.refresh = String(format: "n%d mo%.1f o%.1f c%.1f mx%.1f ia%d f%d r%d fires%d",
                                    PerchTrace.updates, Double(PerchTrace.maxOverscroll),
                                    Double(overscroll), Double(t.crown),
                                    Double(PerchTrace.maxCrown),
                                    t.interacting ? 1 : 0, t.fired ? 1 : 0,
                                    isRefreshing ? 1 : 0, PerchTrace.fires)
        #endif
        // A refresh started: the list springs back, and those frames must not
        // bring the arrow back, or it would sit there until the next scroll.
        if t.fired {
            if overscroll <= 0 { t.fired = false; t.last = 0 }
            return
        }
        if overscroll > 0 {
            // Every nudge at the top adds up. A crown detent is a fresh overscroll
            // (it starts from the top, peaks, and unwinds), while a finger drag keeps
            // the offset growing — so only a nudge that starts near 0 counts, which
            // makes the crown work even though watchOS reports its turns with the
            // scroll view "interacting" like a touch (measured: S17 os=272.5).
            let delta = overscroll - t.last
            if delta > 0, !t.interacting || t.last <= 2 {
                t.crown = min(Self.crownThreshold, t.crown + delta)
            }
        } else if overscroll < -80 {
            // Clearly scrolled down the feed (half a viewport), not the crown band's
            // own undershoot: the top turns keep adding up across a slow crown.
            t.crown = 0
        }
        t.last = overscroll
        guard !isRefreshing else { return }

        let finger = max(0, overscroll) / Self.threshold
        let crown = t.crown / Self.crownThreshold
        let progress = min(1, max(finger, crown))
        pull.set(progress: progress, gap: max(0, overscroll))
        if progress >= 1 {
            setReady(true)
            // Finger down: wait for the release (it can still be pushed back).
            // Crown: nothing to release, refresh as soon as the rubber band has
            // unwound (the turn is over), even if watchOS calls it "interacting".
            if !t.interacting || overscroll <= 2 { fire() }
        } else if t.interacting, finger < 0.7, crown < 1 {
            // Pushed back up before letting go: no refresh (the arrow turns back).
            setReady(false)
        } else {
            scheduleCrownIdle()
        }
    }

    /// The crown stopped short of the threshold: clear the partial pull so the
    /// arrow does not stay on screen until the reader happens to scroll.
    private func scheduleCrownIdle() {
        idleTask?.cancel()
        guard tracker.crown > 0 else { return }
        idleTask = Task {
            try? await Task.sleep(nanoseconds: Self.crownIdle)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !isRefreshing, !tracker.fired else { return }
                // Hide the arrow, keep the travel: a crown turn is slow (simulator:
                // ~3.5 pt per turn) and zeroing here meant the pull could never add up.
                pull.reset()
            }
        }
    }

    private func setReady(_ ready: Bool) {
        guard tracker.ready != ready else { return }
        tracker.ready = ready
        if ready { WKInterfaceDevice.current().play(.click) }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pull.ready = ready }
    }

    private func fire() {
        #if DEBUG
        PerchTrace.fires += 1
        PerchTrace.refresh += " FIRE(ok:\(!isRefreshing && !tracker.fired))"
        #endif
        guard !isRefreshing, !tracker.fired else { return }
        idleTask?.cancel()
        tracker.fired = true
        tracker.crown = 0
        tracker.last = 0
        setReady(false)
        pull.reset()
        Task { await action() }
    }
}

/// What the indicator draws; the only observable part of the pull.
final class PullState: ObservableObject {
    /// 0…1 of a full pull.
    @Published private(set) var progress: CGFloat = 0
    /// Points the list is pulled down (the empty space above the first post).
    @Published private(set) var gap: CGFloat = 0
    /// Past the threshold: letting go refreshes.
    @Published var ready = false
    var topInset: CGFloat = 0

    /// A frame-by-frame value: publish only visible changes.
    func set(progress value: CGFloat, gap: CGFloat) {
        if abs(value - progress) > 0.02 || (value == 0 && progress != 0) || (value == 1 && progress != 1) {
            progress = value
        }
        if abs(gap - self.gap) > 0.5 || (gap == 0 && self.gap != 0) {
            self.gap = gap
        }
    }

    func reset() {
        progress = 0
        gap = 0
        ready = false
    }
}

/// The stretchy arrow at the top of the pull gap: grows with the pull, flips up
/// when letting go will refresh, becomes a small spinning arc while the refresh
/// runs, and a one-second result line when it ends. It sits above the first row,
/// under the clock — never in the middle of the screen.
private struct PullIndicator: View {
    @ObservedObject var state: PullState
    let isRefreshing: Bool
    var failed = false
    var showsStatus = true

    /// Height of the band the indicator occupies.
    private static let band: CGFloat = 25
    /// How far above the content top the band sits (into the toolbar area, so it
    /// never covers the For You / Following tabs).
    private static let lift: CGFloat = 27

    /// The last refresh ended: show "Updated" for a moment.
    @State private var finished = false
    @State private var lastFailed = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        content
            .frame(height: Self.band)
            .frame(maxWidth: .infinity)
            .padding(.top, max(3, state.topInset - Self.lift))
            .onChange(of: isRefreshing) { _, refreshing in
                hideTask?.cancel()
                if refreshing {
                    withAnimation(.easeOut(duration: 0.15)) { finished = false }
                } else {
                    lastFailed = failed
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { finished = true }
                    hideTask = Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            withAnimation(.easeOut(duration: 0.2)) { finished = false }
                        }
                    }
                }
            }
    }

    @ViewBuilder private var content: some View {
        if isRefreshing {
            if showsStatus {
                status(spinner: true, text: "Refreshing", rate: true)
                    .transition(.opacity)
            } else {
                Spinner()
                    .transition(.opacity)
            }
        } else if finished, showsStatus {
            status(spinner: false, text: lastFailed ? "Couldn't update" : "Updated",
                   rate: false, failed: lastFailed)
                .transition(.opacity)
        } else if state.progress > 0.02 {
            arrow
                .transition(.opacity)
        }
    }

    /// The arrow grows down out of the top edge: the shaft stretches with the
    /// pull and the head travels with it, so the empty space is where the motion
    /// happens.
    private var arrow: some View {
        let p = state.progress
        let stretch = min(1, state.gap / PullToRefresh.threshold)
        return VStack(spacing: 0) {
            Capsule()
                .fill(Color.white)
                .frame(width: 2.5, height: 2 + 15 * p + 5 * stretch)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .offset(y: -2)
        }
        .foregroundStyle(.white)
        .rotationEffect(.degrees(state.ready ? 180 : 0))
        .scaleEffect(0.72 + 0.28 * p)
        .opacity(Double(min(1, p * 1.6)))
    }

    private func status(spinner: Bool, text: String, rate: Bool, failed: Bool = false) -> some View {
        HStack(spacing: 5) {
            if spinner {
                Spinner()
            } else {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(failed ? Color.orange : Color.green)
            }
            Text(text)
            if rate {
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    let bps = TransferMonitor.shared.snapshot().bytesPerSecond
                    // Sub-kilobyte traffic is mostly headers: say nothing.
                    if bps >= 500 {
                        Text("· " + TransferMonitor.formatRate(bps))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .lineLimit(1)
    }
}

/// A thin white arc that spins (watchOS draws `ProgressView` as a grey disc here).
private struct Spinner: View {
    var size: CGFloat = 13

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
        }
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
    /// A refresh was fired from this pull: ignore the spring-back frames.
    var fired = false
}

extension View {
    func pullToRefresh(isRefreshing: Bool, failed: Bool = false, showsIndicator: Bool = true,
                       action: @escaping () async -> Void) -> some View {
        modifier(PullToRefresh(isRefreshing: isRefreshing, failed: failed,
                               showsIndicator: showsIndicator, action: action))
    }
}
