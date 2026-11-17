import Foundation
import SwiftUI
import WatchKit
import XKit

/// One home timeline, Parrot style: pure black, no platters, big 19 pt text,
/// full-width media. Infinite scroll, pull- or crown-to-refresh, opens instantly
/// from the on-disk cache. `RootPager` shows one of these per timeline (For You,
/// Following) so swiping between them never reloads anything.
struct HomeView: View {
    let kind: HomeKind
    /// This page is the one the root pager shows (crown focus follows it).
    var isActive: Bool = true

    @EnvironmentObject private var app: AppModel
    @AppStorage(PerchSettings.autoRefreshOnOpen) private var autoRefreshOnOpen = true

    @StateObject private var list = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @State private var configuredFor: String?
    @State private var startedFor: String?
    /// After an account switch: show skeletons (not the previous session's
    /// cached posts) until the new account's first page has arrived.
    @State private var awaitingFresh = false
    /// 0…1: how far a pull/crown turn is towards a refresh (drives the edge glow).
    @State private var pullProgress: CGFloat = 0
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    /// Skeletons instead of "No posts yet" or stale posts: while the first
    /// load runs, before it has even started, and after an account switch.
    private var showsSkeleton: Bool {
        if awaitingFresh, list.error == nil { return true }
        guard list.isEmpty, list.error == nil else { return false }
        return list.isLoading || startedFor != taskKey
    }

    private var glowLoading: Bool {
        (list.isRefreshing || list.isLoading) && !list.isEmpty
    }

    private var taskKey: String {
        "\(kind.rawValue)-\(app.isLoggedIn)-\(app.activeAccountId ?? "none")"
    }

    var body: some View {
        // `ScrollViewReader` instead of `.scrollPosition(id:)`: that binding is
        // rewritten by the system on every scroll and re-applied on every list
        // update, so the feed jumped back to a stale post after refreshes and
        // while pages loaded. We only scroll explicitly, once, when the reader
        // asks for a refresh.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    timelineLabel
                    content
                }
                .padding(.horizontal, Metrics.horizontalPadding)
            }
            .crownScrollFocus(active: isActive)
            .background(Color.black)
            // Loading look: a soft glow around the screen edge (Pigeon-style),
            // drawn once by `RootGlow` over the whole pager; this page reports
            // its pull progress and loading state to `FeedActivity`.
            .onChange(of: pullProgress) { _, p in FeedActivity.shared.setPull(p, for: kind) }
            .onChange(of: glowLoading) { _, loading in FeedActivity.shared.setLoading(loading, for: kind) }
            .onDisappear { FeedActivity.shared.setPull(0, for: kind) }
            .pullToRefresh(isRefreshing: list.isRefreshing, progress: $pullProgress) {
                await refresh(proxy, merge: false)
            }
            .task(id: taskKey) {
                configure()
                await start(proxy)
            }
            .postPresentation(profile: $profileTarget, media: $mediaTarget)
            .onDisappear { list.cancel() }
        }
    }

    /// Which timeline this page is (the menu no longer lists them; the pager's
    /// swipes decide, so the label says where you are).
    private var timelineLabel: some View {
        VStack(spacing: 1) {
            Text(kind == .forYou ? "FOR YOU" : "FOLLOWING")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .accessibilityLabel(kind == .forYou ? "For You timeline" : "Following timeline")
            // Cached posts on screen but the last refresh failed: say so, instead
            // of an error line at the very bottom of the feed nobody sees.
            if !list.isEmpty, list.error != nil, !list.isRefreshing {
                Label(offlineText, systemImage: "wifi.slash")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private var offlineText: String {
        guard let d = list.lastUpdated else { return "Offline · cached posts" }
        return "Offline · updated \(RelativeTime.short(d)) ago"
    }

    @ViewBuilder
    private var content: some View {
        if let e = list.error, list.isEmpty {
            ErrorStateView(error: e) { await list.refresh() }
                .padding(.vertical, 16)
        } else if showsSkeleton {
            VStack(spacing: 12) {
                PostSkeleton(mediaHeight: 130)
                PostSkeleton(mediaHeight: 110)
                PostSkeleton(mediaHeight: 150)
            }
            .padding(.vertical, 4)
        } else if list.isEmpty {
            emptyState
        } else {
            // A refresh the reader asked for: a placeholder post at the top
            // shows where the new posts will appear (with the edge glow).
            if list.isRefreshing && !awaitingFresh {
                PostSkeleton(mediaHeight: 90)
                    .transition(.opacity)
                PostSeparator()
            }
            ForEach(list.items) { item in
                VStack(alignment: .leading, spacing: 0) {
                    TimelineItemRows(item: item,
                                     onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                     onMedia: { mediaTarget = $0 })
                        .onAppear { list.loadMoreIfNeeded(current: item) }
                    if item.id != list.items.last?.id { PostSeparator() }
                }
                .id(item.id)
            }
            PagingFooter(isLoading: list.isLoading && !list.isRefreshing,
                         error: list.error, retry: { list.retryMore() })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "bird")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No posts yet")
                .font(.system(size: 15, weight: .semibold))
            Text("Pull down or turn the crown to refresh.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func configure() {
        let key = taskKey
        guard configuredFor != key else { return }
        // Not the first configure of this page: the account (or login) changed.
        awaitingFresh = configuredFor != nil
        configuredFor = key
        list.reset()

        let client = app.client
        let k = kind
        let cacheName = app.timelineCacheName(k)
        list.fetch = { cursor in
            let p = try await client.homeTimeline(k, cursor: cursor)
            return (p.items, p.bottomCursor, p.topCursor)
        }
        list.onFirstPage = { items, _ in
            TimelineDiskCache.save(items, name: cacheName)
        }
        list.onPage = { items in
            ImageLoader.shared.prefetchFeed(items.displayTweets)
        }
        list.skip = { $0.isFiller }
        list.seed(TimelineDiskCache.load(name: cacheName))
    }

    /// Show the cached feed immediately; only go to the network when
    /// "Refresh when opening the app" is on, or when there is no cache at all.
    /// Runs once per account/kind so closing a sheet does not re-fetch.
    ///
    /// Marked as started only once the load really finished: `.task` is
    /// cancelled when the page disappears (swiping to the other feed or the
    /// menu, opening a post), and a cancelled first load used to leave the feed
    /// empty until a manual pull.
    private func start(_ proxy: ScrollViewProxy) async {
        let key = taskKey
        guard startedFor != key else { return }
        if !list.isEmpty { FeedActivity.shared.markContentReady() }   // cached posts
        if list.isEmpty || autoRefreshOnOpen || awaitingFresh {
            // Merge, so posts that are already on screen are never reordered or
            // dropped: only new ones appear above them.
            await refresh(proxy, merge: !awaitingFresh)
        }
        if !Task.isCancelled {
            startedFor = key
            awaitingFresh = false
            FeedActivity.shared.markContentReady()
        }
    }

    private func refresh(_ proxy: ScrollViewProxy, merge: Bool) async {
        await list.refresh(merge: merge)
        // Offline taps (like/repost/bookmark) go out as soon as we are online.
        await app.posts.flush(client: app.client)
        // A refresh the reader asked for (pull / crown) brings them to the top;
        // the silent one on open leaves the scroll position alone.
        guard !merge, !list.items.isEmpty else { return }
        // The list has to lay out its first row before `scrollTo` can find it.
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !list.items.isEmpty else { return }
        proxy.scrollTo(list.items[0].id, anchor: .top)
    }
}

/// What the feeds are doing, for the single glow over the root pager.
@MainActor
final class FeedActivity: ObservableObject {
    static let shared = FeedActivity()

    @Published private(set) var loading: Set<HomeKind> = []
    /// The first feed has something to show (cached or fresh posts, or a
    /// finished load): the launch intro ends then, never later.
    @Published private(set) var firstContentReady = false

    func markContentReady() {
        if !firstContentReady { firstContentReady = true }
    }
    @Published private(set) var pull: [HomeKind: CGFloat] = [:]

    func setLoading(_ on: Bool, for kind: HomeKind) {
        if on { loading.insert(kind) } else { loading.remove(kind) }
    }

    func setPull(_ value: CGFloat, for kind: HomeKind) {
        if pull[kind] != value { pull[kind] = value }
    }
}

/// The pager-wide glow. Its own view so per-frame pull updates only redraw it,
/// not the pager. Loading anywhere (either feed) shows the pulse on every page;
/// the pull fill follows the feed on screen.
struct RootGlow: View {
    let page: Int
    @ObservedObject private var activity = FeedActivity.shared

    var body: some View {
        let kind: HomeKind? = page == 1 ? .forYou : (page == 2 ? .following : nil)
        EdgeGlow(progress: kind.flatMap { activity.pull[$0] } ?? 0,
                 loading: !activity.loading.isEmpty)
    }
}

/// Corner radius of the watch display, so the glow follows the screen edge
/// instead of being clipped by the rounded corners. watchOS has no public API
/// for it and Apple publishes no figure, so this is an estimate from the screen
/// width (22%), tuned by eye on a Series 10. If the ring still touches a
/// corner on some model, raise the factor.
enum DisplayShape {
    static var cornerRadius: CGFloat {
        let w = WKInterfaceDevice.current().screenBounds.width
        return (w * 0.22).rounded()
    }
}

/// Loading look: a rainbow ring glowing around the screen edge (Pigeon-style).
/// It brightens as a pull/crown turn fills up; while the feed loads it pulses
/// and its colours flow around the screen. There is no progress text.
///
/// Drawn as plain gradient strokes (no full-screen blur, which is costly on the
/// Watch GPU). The loading animation lives in its own subview that is removed
/// when loading ends, so it stops for good instead of leaking a repeat-forever
/// animation into the feed's layout.
struct EdgeGlow: View {
    var progress: CGFloat = 0
    var loading: Bool = false

    var body: some View {
        ZStack {
            if loading {
                LoadingGlow()
                    .transition(.opacity)
            } else if progress > 0.03 {
                GlowShape()
                    .opacity(0.25 + 0.6 * Double(min(1, max(0, progress))))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: loading)
    }
}

/// Pulses (brightness + a slight breathing width) and rotates the hues.
private struct LoadingGlow: View {
    @State private var hue: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GlowShape()
            .hueRotation(.degrees(hue))
            .animation(reduceMotion ? nil : .linear(duration: 2.4).repeatForever(autoreverses: false), value: hue)
            .phaseAnimator([false, true]) { content, bright in
                content
                    .opacity(bright ? 0.95 : 0.35)
                    .scaleEffect(bright ? 1 : 0.985)
            } animation: { _ in .easeInOut(duration: 0.9) }
            .onAppear { if !reduceMotion { hue = 360 } }
    }
}

private struct GlowShape: View {
    private static let rainbow = AngularGradient(
        colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red],
        center: .center)

    var body: some View {
        ZStack {
            // Both strokes sit fully inside a shape with the display's own corner
            // radius, so no part of the ring falls into the clipped corners.
            RoundedRectangle(cornerRadius: DisplayShape.cornerRadius, style: .continuous)
                .strokeBorder(Self.rainbow, lineWidth: 7)
                .opacity(0.35)
            RoundedRectangle(cornerRadius: max(0, DisplayShape.cornerRadius - 2), style: .continuous)
                .strokeBorder(Self.rainbow, lineWidth: 2)
                .padding(2)
        }
    }
}
