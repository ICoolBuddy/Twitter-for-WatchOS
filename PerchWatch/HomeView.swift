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
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    /// Skeletons instead of "No posts yet" or stale posts: while the first
    /// load runs, before it has even started, and after an account switch.
    private var showsSkeleton: Bool {
        if awaitingFresh, list.error == nil { return true }
        guard list.isEmpty, list.error == nil else { return false }
        return list.isLoading || startedFor != taskKey
    }

    /// The feed is talking to the network: a refresh (pull, crown, on open,
    /// after an account switch) or the next page. This alone drives the edge glow.
    private var fetching: Bool {
        list.isRefreshing || list.isLoading
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
            // drawn once by `RootGlow` over the whole pager. It follows network
            // activity only; pulling or turning the crown merely triggers a
            // refresh (an overscroll-driven glow stayed lit at the top of the
            // feed with nothing loading). `initial` so a load already running
            // when the page appears is reported too.
            .onChange(of: fetching, initial: true) { _, on in FeedActivity.shared.setLoading(on, for: kind) }
            .pullToRefresh(isRefreshing: list.isRefreshing) {
                await refresh(proxy, merge: false)
            }
            .task(id: taskKey) {
                configure()
                await start(proxy)
            }
            .postPresentation(profile: $profileTarget, media: $mediaTarget)
            .onDisappear {
                list.cancel()
                // A cancelled load must not leave the glow pulsing.
                FeedActivity.shared.setLoading(false, for: kind)
            }
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

    func setLoading(_ on: Bool, for kind: HomeKind) {
        if on, !loading.contains(kind) { loading.insert(kind) }
        if !on, loading.contains(kind) { loading.remove(kind) }
    }
}

/// The pager-wide glow. Its own view so loading changes only redraw it, not
/// the pager. Fetching in either feed shows the pulse on every page, so a
/// refresh still running after a swipe stays visible.
struct RootGlow: View {
    @ObservedObject private var activity = FeedActivity.shared

    var body: some View {
        EdgeGlow(loading: !activity.loading.isEmpty)
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

/// Loading look: a thin ring around the screen edge (Pigeon-style) that pulses
/// softly while a feed fetches, and is invisible otherwise. No progress text.
///
/// Drawn as one plain stroke (no full-screen blur, which is costly on the
/// Watch GPU). The loading animation lives in its own subview that is removed
/// when loading ends, so it stops for good instead of leaking a repeat-forever
/// animation into the feed's layout.
struct EdgeGlow: View {
    var loading: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One pulse (dim → bright → dim), seconds.
    private static let period: Double = 1.8

    // The pulse is computed from the clock (TimelineView), not animated:
    // a repeat-forever implicit animation also animated every layout change
    // made while it ran, which made the ring shrink and grow on a cold start.
    // Paused (no redraws at all) whenever nothing is loading.
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !loading || reduceMotion)) { context in
            GlowShape()
                .opacity(opacity(at: context.date))
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func opacity(at date: Date) -> Double {
        if loading {
            if reduceMotion { return 0.6 }
            let phase = date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.period) / Self.period
            return 0.25 + 0.55 * (0.5 - 0.5 * cos(phase * 2 * .pi))
        }
        return 0
    }
}

/// One thin white ring inside the display's rounded corners.
private struct GlowShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: DisplayShape.cornerRadius, style: .continuous)
            .strokeBorder(Color.white, lineWidth: 2)
    }
}
