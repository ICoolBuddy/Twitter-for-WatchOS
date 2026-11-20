import Foundation
import XKit

/// Configure, seed and start one home feed. This lives outside `HomeView` because the
/// system pager builds a page only when it is first selected: before this, the
/// off-screen feed's `PagedList` kept its placeholder `fetch` (which returns an empty
/// page) until the reader swiped to it — so Following was only refreshed on arrival.
@MainActor
struct HomeFeedSetup {
    let kind: HomeKind
    let list: PagedList<TimelineItem>
    let place: FeedPlace
    let visibility: PageVisibility
    let key: String

    static func key(_ kind: HomeKind, loggedIn: Bool, accountId: String?) -> String {
        "\(kind.rawValue)-\(loggedIn)-\(accountId ?? "none")"
    }

    func configure(client: XClient, scope: TimelineCacheScope) {
        // Kept in `place` (owned by RootPager, like the list): reconfiguring a feed
        // that is already set up would reset the shared list.
        guard place.configuredFor != key else { return }
        // Not the first configure of this feed: the account (or login) changed.
        place.accountChanged = place.configuredFor != nil
        if place.accountChanged {
            // Another account's reading place means nothing here.
            place.liveTopID = nil
            place.seen.reset()
        }
        place.configuredFor = key
        list.reset()

        let k = kind
        let seen = place.seen
        let visibility = self.visibility
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
        list.onPage = { items in
            // Both feeds stay alive in the pager: only the one on screen warms images.
            guard visibility.isActive else { return }
            let warm = Array(items.prefix(LinkBudget.prefetchPostCount))
            ImageLoader.shared.prefetchFeed(warm.displayTweets)
        }
        list.skip = { $0.isFiller }
    }

    func seed(_ cached: [TimelineItem]) { list.seed(cached) }

    /// Show the cached feed immediately; only go to the network when "Refresh when
    /// opening the app" is on, there is no cache, or the account changed. Runs until
    /// the list itself says this configuration has loaded (`hasLoadedFirstPage`), so a
    /// load cancelled by swiping away or opening a post is retried on the next
    /// appearance, and an account switched back and forth can never skip its fetch.
    func start(client: XClient, posts: PostStateStore, autoRefreshOnOpen: Bool) async {
        guard !list.hasLoadedFirstPage, !list.isFetching else { return }
        if !list.isEmpty { FeedActivity.shared.markContentReady() }   // cached posts
        if list.isEmpty || autoRefreshOnOpen || place.accountChanged {
            // Merge, so posts already on screen are never reordered or dropped: only
            // new ones appear above them. After an account switch, replace.
            await list.refresh(merge: !place.accountChanged)
            // Offline taps (like/repost/bookmark) go out as soon as we are online.
            await posts.flush(client: client)
        }
        if !Task.isCancelled {
            if list.hasLoadedFirstPage { place.accountChanged = false }
            FeedActivity.shared.markContentReady()
        }
    }
}
