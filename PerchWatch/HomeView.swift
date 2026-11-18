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
    /// Tapping the other tab at the top switches feeds (the pager owns the page).
    var onSelect: ((HomeKind) -> Void)? = nil

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
    /// Black over the list while a restore lands (a frame or two), so a page that
    /// comes back never shows the top first and then jumps to the reader's place.
    @State private var coverWhileRestoring = false
    /// The `returnToken` whose scroll view has been put back at the reader's place.
    /// Different from `returnToken` = a rebuilt scroll view that has not been
    /// restored yet: covered from its very first frame (setting a flag in
    /// `onChange` came one frame late, and a fast swipe back showed that frame).
    @State private var restoredToken = 0

    /// Black over the list: a restore is running, or a new scroll view (rebuilt, or a
    /// page the pager created again) has not been put back at the reader's place yet.
    private var covered: Bool {
        coverWhileRestoring || returnToken != restoredToken || (!hasAppeared && place.savedTopID != nil)
    }

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
            .overlay {
                if covered { Color.black.allowsHitTesting(false) }
            }
            .onScrollGeometryChange(for: CGSize.self) {
                CGSize(width: $0.contentInsets.top, height: $0.containerSize.height)
            } action: { _, g in
                place.topInset = g.width
                place.viewportHeight = g.height
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
                // Arriving on this feed: warm what it is about to show.
                if active, !list.isEmpty { ImageLoader.shared.prefetchFeed(list.items.displayTweets) }
            }
            .onDisappear { list.cancel() }
        }
    }

    /// X-style tabs: both feeds named, the current one bold white with a blue bar.
    /// The first row of the list, so it scrolls away with the posts (owner,
    /// 2026-11-18: not pinned). Tapping the other name switches feeds.
    private var timelineLabel: some View {
        VStack(spacing: 2) {
            HStack(spacing: 16) {
                feedTab(.forYou, "For You")
                feedTab(.following, "Following")
            }
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

    private func feedTab(_ tab: HomeKind, _ title: String) -> some View {
        let current = tab == kind
        return Button {
            if !current { onSelect?(tab) }
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: current ? .bold : .medium))
                    .foregroundStyle(current ? Color.white : Color.white.opacity(0.45))
                Capsule()
                    .fill(current ? Self.tabBlue : Color.clear)
                    .frame(width: 26, height: 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.swipeSafe)
        .accessibilityLabel(title + " timeline")
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    /// X's own blue.
    private static let tabBlue = Color(red: 0.114, green: 0.608, blue: 0.941)

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
                // Where this row is on screen: the reading place and the "seen"
                // impressions come from real row frames. (onScrollTargetVisibilityChange
                // reported rows ~1000 pt above the viewport here: measured 2026-11-18.)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                    // A page created a moment ago starts at the top: its rows must not
                    // overwrite the place before `restore` has run (`hasAppeared`).
                    place.rowMoved(item, frame: frame, isFirst: item.id == list.items.first?.id,
                                   active: visibility.isActive && hasAppeared)
                }
            }
            PagingFooter(list: list)
        }
    }

    /// Scrolls a new scroll view back to the post that was on top when the reader
    /// left this feed. Nothing to do on the very first appearance (no saved place).
    /// Puts a new scroll view back at the reader's exact place: first the saved row
    /// to the top, then `FeedPlace` corrects by measuring where the row really landed
    /// (the new list has not measured the rows above it, so one scroll is not exact).
    private func restore(_ proxy: ScrollViewProxy) {
        let token = returnToken
        guard let id = place.savedTopID, list.items.contains(where: { $0.id == id }) else {
            restoredToken = token
            return
        }
        coverWhileRestoring = true
        place.beginRestore({ id, anchor in proxy.scrollTo(id, anchor: anchor) },
                           done: {
                               coverWhileRestoring = false
                               restoredToken = token
                           })
    }

    #if DEBUG
    /// Restore evidence for the place tests (refreshed on each body pass).
    private var placeDebug: String {
        "saved=\(place.savedTopID ?? "-") live=\(place.liveTopID ?? "-") d=\(Int(place.savedDepth)) inset=\(Int(place.topInset)) vh=\(Int(place.viewportHeight))"
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
    /// How far (points) the viewport top was inside the top row, live and saved.
    var liveDepth: CGFloat = 0
    var savedDepth: CGFloat = 0
    /// An exact restore in flight (see `beginRestore`).
    private var restoring: (id: String, tries: Int, a0: CGFloat, top0: CGFloat?, a: CGFloat,
                            lastTop: CGFloat?)?
    private var scrollToRow: ((String, UnitPoint) -> Void)?
    /// The scroll view's visible height (what "on screen" means for a row frame).
    var viewportHeight: CGFloat = 0
    /// The scroll view's top inset (under the toolbar): where reading starts.
    var topInset: CGFloat = 0
    /// Posts the reader has had on screen in this feed (see `FeedSeen`).
    let seen = FeedSeen()

    /// One row's frame in the scroll view's visible coordinates changed.
    /// Called when a restore finished (or gave up).
    private var restoreDone: (() -> Void)?

    func rowMoved(_ item: TimelineItem, frame: CGRect, isFirst: Bool, active: Bool) {
        let top = topInset
        if let r = restoring, r.id == item.id {
            correct(frame: frame)
            return
        }
        guard active, restoring == nil else { return }
        let height = viewportHeight > 0 ? viewportHeight : 150
        // On screen at all: an impression (sent with the next home request).
        if frame.maxY > top + 8, frame.minY < height - 8 { seen.mark(item) }
        if frame.minY <= top + 0.5, frame.maxY > top + 0.5 {
            // This row covers the top edge of the viewport: it is the reading place.
            liveTopID = item.id
            liveDepth = top - frame.minY
        } else if isFirst, frame.minY > top + 0.5 {
            liveTopID = nil          // the top of the feed (label/anchor) is showing
            liveDepth = 0
        }
        // Saved continuously, not when the feed is left: the system pager can drop
        // the page in the same update that makes it inactive, so a "save on leave"
        // never ran (device: back at the top, later at a long-gone post).
        savedTopID = liveTopID
        savedDepth = liveDepth
    }

    private func finishRestore() {
        restoring = nil
        let done = restoreDone
        restoreDone = nil
        done?()
    }

    /// Starts an exact restore: the saved row is scrolled to anchor 0 (its top at
    /// the viewport top), then `correct` measures and re-aims.
    func beginRestore(_ scroll: @escaping (String, UnitPoint) -> Void, done: @escaping () -> Void) {
        guard let id = savedTopID else { done(); return }
        scrollToRow = scroll
        restoreDone?()
        restoreDone = done
        restoring = (id, 0, 0, nil, 0, nil)
        liveTopID = id
        liveDepth = savedDepth
        DispatchQueue.main.async { scroll(id, UnitPoint(x: 0.5, y: 0)) }
        // Belt: a row that never reports a frame must not freeze place tracking
        // (or leave the list covered).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            if self?.restoring?.id == id { self?.finishRestore() }
        }
    }

    /// Where the restored row landed vs. where it was (`savedDepth` into it).
    /// `scrollTo(id, anchor: a)` moves the row top linearly with `a`; two
    /// measurements give the slope (secant step), so it converges in a step or two
    /// without assuming how watchOS measures the viewport.
    private func correct(frame: CGRect) {
        guard var r = restoring, let scroll = scrollToRow else { return }
        let rowTop = frame.minY
        if let last = r.lastTop, abs(last - rowTop) < 0.25 { return }   // same frame again
        r.lastTop = rowTop
        let desired = topInset - savedDepth
        let error = rowTop - desired
        if abs(error) <= 1.5 || r.tries >= 4 {
            liveDepth = topInset - rowTop
            finishRestore()
            return
        }
        let next: CGFloat
        if let top0 = r.top0, abs(r.a - r.a0) > 0.0001, abs(rowTop - top0) > 0.5 {
            let slope = (rowTop - top0) / (r.a - r.a0)
            next = r.a - error / slope
            r.a0 = r.a
            r.top0 = rowTop
        } else {
            // First measurement: guess the slope from the sizes (row taller than the
            // viewport moves up as `a` grows), then refine with the secant.
            let v = viewportHeight > 0 ? viewportHeight : 150
            let h = max(frame.height, 1)
            let slope = (v - h) == 0 ? -1 : (v - h)
            next = r.a - error / slope
            r.a0 = r.a
            r.top0 = rowTop
        }
        r.a = next
        r.tries += 1
        restoring = r
        let id = r.id
        DispatchQueue.main.async { scroll(id, UnitPoint(x: 0.5, y: next)) }
    }
    /// The account/login the shared list was configured for (`HomeView.taskKey`).
    var configuredFor: String?
    /// The account changed since the feed was first configured: the next refresh
    /// replaces the list instead of merging into it.
    var accountChanged = false
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
