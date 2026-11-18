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
    /// Bumped by `RootPager` when this feed is swiped back to. The scroll view gets a
    /// new identity so it *appears* again — watchOS hands the Digital Crown to a
    /// scroll view that appears, not to one a page swipe merely brings back (crown
    /// routing test S3) — and the reader is put back on the post they were reading.
    var returnToken = 0

    @EnvironmentObject private var app: AppModel
    @AppStorage(PerchSettings.autoRefreshOnOpen) private var autoRefreshOnOpen = true

    /// Owned by `RootPager`, which also draws the edge glow from it.
    @ObservedObject var list: PagedList<TimelineItem>
    /// Where the reader was, owned by `RootPager` so it survives this page being
    /// rebuilt (`returnToken`) or dropped by the system pager while off screen.
    let place: FeedPlace
    /// `PagedList` keeps the closures it was configured with, so they cannot read the
    /// `isActive` struct property later: this box carries the live value.
    @State private var visibility = PageVisibility()
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?
    /// False only for a freshly created page (the system pager can drop an
    /// off-screen page and build it again): that one restores `place` on appear.
    @State private var hasAppeared = false
    /// EXPERIMENT (variant O): restore by content offset instead of by post id.
    @State private var offsetPosition = ScrollPosition(idType: String.self)

    /// The top of the list: a zero-height anchor laid out before any row, so a refresh
    /// can scroll up without waiting for the new first post to exist.
    private static let topAnchor = "perch-feed-top"

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
                    Color.clear.frame(height: 0).id(Self.topAnchor)
                    timelineLabel
                    content
                }
                .scrollTargetLayout()
                .padding(.horizontal, Metrics.horizontalPadding)
            }
            .background(Color.black)
            .modifier(OffsetRestore(position: $offsetPosition, active: MediaLab.has("O")))
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                if visibility.isActive, place.restoringY == nil { place.liveY = y }
            }
            .id(returnToken)
            #if DEBUG
            .overlay(alignment: .topTrailing) {
                Text(verbatim: "place")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("place." + (kind == .forYou ? "forYou" : "following"))
                    .accessibilityValue(placeDebug)
            }
            #endif
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.3) { ids in
                // Only while this feed is the one being read: a page leaving the
                // screen (or a rebuilt one, which starts at the top) must not
                // overwrite where the reader was.
                guard visibility.isActive else { return }
                let visible = Set(ids)
                let top = list.items.first(where: { visible.contains($0.id) })?.id
                // A restore in flight: a LazyVStack scrolled to a row it has not
                // measured yet lands short (measured: y 1989 -> 760), so aim again
                // each time it reports where it really is, a few times at most.
                if let target = place.restoringID {
                    if top == target || place.restoreTries >= 4 {
                        place.restoringID = nil
                    } else {
                        place.restoreTries += 1
                        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
                        return
                    }
                }
                // What X calls an impression: sent with the next home request.
                for item in list.items where visible.contains(item.id) {
                    place.seen.mark(item)
                }
                if let top {
                    place.liveTopID = top
                } else if visible.contains(Self.topAnchor) {
                    place.liveTopID = nil
                }
            }
            // Swiped back to: the scroll view was rebuilt (crown), put the reader back.
            .onChange(of: returnToken) { _, _ in restore(proxy) }
            .onAppear {
                guard !hasAppeared else { return }
                hasAppeared = true
                restore(proxy)
            }
            // The edge glow is drawn by `RootGlow` straight from the lists; pulling
            // or turning the crown only triggers the refresh.
            .pullToRefresh(isRefreshing: list.isRefreshing, failed: list.error != nil) {
                // Like X: newer posts above the ones already loaded, never a reload.
                await list.refreshNewer()
                await app.posts.flush(client: app.client)
                // A refresh the reader asked for brings the new posts into view;
                // animated, and a no-op when the pull already left the list at the top.
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
            }
            // crown-lab measurement hook (DEBUG only, a no-op in Release): publishes
            // this list's offset as `probe.feed.forYou` / `probe.feed.following`.
            .crownProbe(kind == .forYou ? "feed.forYou" : "feed.following")
            .task(id: taskKey) {
                configure()
                // The disk cache is read off the main thread, before the first fetch.
                list.seed(await TimelineDiskCache.loadAsync(app.homeCacheScope(kind)))
                await start()
            }
            .postPresentation(profile: $profileTarget, media: $mediaTarget)
            .onChange(of: isActive, initial: true) { _, active in
                visibility.isActive = active
                // Leaving this feed (page swipe, menu, pushed screen): keep the place.
                if !active {
                    place.savedTopID = place.liveTopID
                    place.savedY = place.liveY
                }
                // Arriving on this feed: warm what it is about to show.
                if active, !list.isEmpty { ImageLoader.shared.prefetchFeed(list.items.displayTweets) }
            }
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
        // Skeletons until the first page for this account/timeline has loaded; a seeded
        // cache (the new account's own after a switch, too) shows immediately instead.
        PagedListStatus(list: list, emptyText: "No posts yet",
                        emptyHint: "Pull down or turn the crown to refresh.",
                        loading: .postSkeletons)
            .padding(.vertical, list.phase == .empty ? 10 : 0)
        if !list.isEmpty {
            ForEach(list.items) { item in
                VStack(alignment: .leading, spacing: 0) {
                    TimelineItemRows(item: item,
                                     onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                     onMedia: { mediaTarget = $0 })
                        .paginates(list, with: item)
                    if item.id != list.items.last?.id { PostSeparator() }
                }
                .id(item.id)
            }
            PagingFooter(list: list)
        }
    }

    /// Scrolls a new scroll view back to the post that was on top when the reader
    /// left this feed. Nothing to do on the very first appearance (no saved place).
    private func restore(_ proxy: ScrollViewProxy) {
        if MediaLab.has("O") {
            guard let y = place.savedY, y > 1 else { return }
            place.restoringY = y
            DispatchQueue.main.async {
                offsetPosition.scrollTo(y: y)
                DispatchQueue.main.async { place.restoringY = nil }
            }
            return
        }
        guard let id = place.savedTopID, list.items.contains(where: { $0.id == id }) else { return }
        place.liveTopID = id
        place.restoringID = id
        place.restoreTries = 0
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }

    #if DEBUG
    /// Restore evidence for the place tests (refreshed on each body pass).
    private var placeDebug: String {
        "saved=\(place.savedTopID ?? "-") live=\(place.liveTopID ?? "-") tries=\(place.restoreTries) savedY=\(Int(place.savedY ?? -1)) liveY=\(Int(place.liveY ?? -1))"
    }
    #endif

    private func configure() {
        let key = taskKey
        // Kept in `place` (owned by RootPager, like the list): a page the system
        // pager rebuilt is not a new configuration, and resetting the shared list
        // there threw away the posts and the place it had just restored.
        guard place.configuredFor != key else { return }
        // Not the first configure of this feed: the account (or login) changed.
        place.accountChanged = place.configuredFor != nil
        if place.accountChanged {
            // Another account's reading place means nothing here.
            place.liveTopID = nil
            place.savedTopID = nil
            place.seen.reset()
        }
        place.configuredFor = key
        list.reset()

        let client = app.client
        let k = kind
        let scope = app.homeCacheScope(k)
        let seen = place.seen
        list.fetch = { cursor in
            let ids = await MainActor.run { seen.drain() }
            let p = try await client.homeTimeline(k, cursor: cursor, context: .launch, seenTweetIds: ids)
            return (p.items, p.bottomCursor, p.topCursor)
        }
        list.topFetch = { top in
            let ids = await MainActor.run { seen.drain() }
            let p = try await client.homeTimeline(k, cursor: top, context: .refresh, seenTweetIds: ids)
            return (p.items, p.bottomCursor, p.topCursor)
        }
        list.alreadySeen = { seen.wasSeen($0) }
        list.onFirstPage = { items, _ in
            TimelineDiskCache.save(items, scope: scope)
        }
        let visibility = self.visibility
        list.onPage = { items in
            // Both feeds stay alive in the pager: only the one on screen warms images.
            guard visibility.isActive else { return }
            ImageLoader.shared.prefetchFeed(items.displayTweets)
        }
        list.skip = { $0.isFiller }
    }

    /// Show the cached feed immediately; only go to the network when "Refresh when
    /// opening the app" is on, there is no cache, or the account changed. Runs until
    /// the list itself says this configuration has loaded (`hasLoadedFirstPage`), so a
    /// load cancelled by swiping away or opening a post is retried on the next
    /// appearance, and an account switched back and forth can never skip its fetch.
    private func start() async {
        guard !list.hasLoadedFirstPage else { return }
        if !list.isEmpty { FeedActivity.shared.markContentReady() }   // cached posts
        if list.isEmpty || autoRefreshOnOpen || place.accountChanged {
            // Merge, so posts already on screen are never reordered or dropped: only
            // new ones appear above them. After an account switch, replace.
            await refresh(merge: !place.accountChanged)
        }
        if !Task.isCancelled {
            if list.hasLoadedFirstPage { place.accountChanged = false }
            FeedActivity.shared.markContentReady()
        }
    }

    private func refresh(merge: Bool) async {
        await list.refresh(merge: merge)
        // Offline taps (like/repost/bookmark) go out as soon as we are online.
        await app.posts.flush(client: app.client)
    }
}

/// The reading place of one home feed. A plain reference (not observed): updating
/// it on every scrolled post must not re-render the pager.
final class FeedPlace {
    /// The first post on screen right now (only tracked while the feed is active).
    var liveTopID: String?
    /// `liveTopID` at the moment the reader left the feed: what a rebuilt scroll
    /// view returns to.
    var savedTopID: String?
    /// Content offset, for the offset-based restore experiment (variant O).
    var liveY: CGFloat?
    var savedY: CGFloat?
    var restoringY: CGFloat?
    /// Posts the reader has had on screen in this feed (see `FeedSeen`).
    let seen = FeedSeen()
    /// A restore that has not landed on its post yet, and how often it re-aimed.
    var restoringID: String?
    var restoreTries = 0
    /// The account/login the shared list was configured for (`HomeView.taskKey`).
    var configuredFor: String?
    /// The account changed since the feed was first configured: the next refresh
    /// replaces the list instead of merging into it.
    var accountChanged = false
}

/// EXPERIMENT (variant O): the scroll view gets a `ScrollPosition` only in that variant.
private struct OffsetRestore: ViewModifier {
    @Binding var position: ScrollPosition
    let active: Bool

    func body(content: Content) -> some View {
        if active { content.scrollPosition($position) } else { content }
    }
}

/// The posts a reader has seen in one home feed, kept the way x.com's web client
/// keeps them: `pending` = seen since the last home request (sent as `seenTweetIds`,
/// then cleared), `known` = every row seen this session, so a refresh never puts one
/// back on top as new. Main thread only (visibility callbacks and `MainActor.run`).
final class FeedSeen {
    private var pending: [String] = []
    private var pendingSet: Set<String> = []
    private var known: Set<String> = []
    /// Bounds: X's own tracker sends what was seen since the last request (a few
    /// dozen); `known` only has to cover a session of reading.
    private static let maxPending = 100
    private static let maxKnown = 3000

    func mark(_ item: TimelineItem) {
        // Only the first time a row is seen: it was already reported after that.
        guard known.insert(item.id).inserted else { return }
        if known.count > Self.maxKnown { known.removeAll(keepingCapacity: true); known.insert(item.id) }
        for tweet in item.tweets {
            let id = tweet.displayed.id
            guard pending.count < Self.maxPending, pendingSet.insert(id).inserted else { continue }
            pending.append(id)
        }
    }

    func wasSeen(_ item: TimelineItem) -> Bool { known.contains(item.id) }

    /// The ids for the next request; cleared, as the web client does after sending.
    func drain() -> [String] {
        defer { pending.removeAll(); pendingSet.removeAll() }
        return pending
    }

    func reset() {
        pending.removeAll()
        pendingSet.removeAll()
        known.removeAll()
    }
}

/// Whether a feed page is the one on screen, readable from closures stored earlier.
final class PageVisibility {
    var isActive = true
}

/// Launch gate for the intro animation.
@MainActor
final class FeedActivity: ObservableObject {
    static let shared = FeedActivity()

    /// The first feed has something to show (cached or fresh posts, or a
    /// finished load): the launch intro ends then, never later.
    @Published private(set) var firstContentReady = false

    func markContentReady() {
        if !firstContentReady { firstContentReady = true }
    }
}

/// The pager-wide glow, read straight from the two feed lists (the source of truth,
/// no mirror). It pulses only while a feed *refreshes* (pull, crown, on open, account
/// switch); loading older posts at the bottom has its own spinner. A refresh still
/// running after a swipe stays visible on every page.
struct RootGlow: View {
    @ObservedObject var forYou: PagedList<TimelineItem>
    @ObservedObject var following: PagedList<TimelineItem>

    var body: some View {
        EdgeGlow(loading: forYou.isRefreshing || following.isRefreshing)
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
        return (w * 0.235).rounded()
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

/// Pigeon-style edge glow: a bright rim on the display edge that fades softly
/// inwards over ~14 pt.
///
/// Built from concentric bands (each inset by one band width, with the corner
/// radius shrunk by the same amount so they stay parallel) whose opacity falls
/// off quadratically, instead of blurring a full-screen layer, which is costly
/// on the Watch GPU. `drawingGroup()` flattens the bands into one layer once,
/// so the pulse only changes that layer's opacity.
private struct GlowShape: View {
    /// Number of bands and the width of each, in points.
    private static let bands = 10
    private static let band: CGFloat = 1.4
    /// Opacity of the band next to the rim (the rim itself is fully opaque).
    private static let innerStart = 0.55

    var body: some View {
        let radius = DisplayShape.cornerRadius
        ZStack {
            ForEach(0..<Self.bands, id: \.self) { i in
                let inset = CGFloat(i) * Self.band
                RoundedRectangle(cornerRadius: max(0, radius - inset), style: .continuous)
                    .strokeBorder(Color.white.opacity(Self.opacity(band: i)),
                                  lineWidth: i == 0 ? 2 : Self.band)
                    .padding(inset)
            }
        }
        .drawingGroup()
    }

    private static func opacity(band i: Int) -> Double {
        guard i > 0 else { return 1 }
        let t = Double(i) / Double(bands)      // 0 at the rim … 1 at the inner edge
        return innerStart * (1 - t) * (1 - t)
    }
}
