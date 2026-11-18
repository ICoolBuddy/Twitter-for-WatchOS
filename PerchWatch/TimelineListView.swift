import SwiftUI
import XKit

/// Likes / Bookmarks timelines (both live in the Menu). Infinite scroll, no
/// disk cache: they are one tap away and change often.
struct TimelineListView: View {
    enum Kind: String {
        case likes
        case bookmarks
    }

    let kind: Kind
    let title: String

    @EnvironmentObject private var app: AppModel
    @StateObject private var list = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @State private var configuredKey: String?
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PagedListStatus(list: list, emptyText: emptyText)

                ForEach(list.items) { item in
                    TimelineItemRows(item: item,
                                     onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                     onMedia: { mediaTarget = $0 })
                        .paginates(list, with: item)
                    PostSeparator()
                }

                PagingFooter(list: list)
            }
            .padding(.horizontal, Metrics.horizontalPadding)
        }
        .pagedListChrome(list, onRefresh: { await list.refresh() },
                         profile: $profileTarget, media: $mediaTarget)
        .navigationTitle(title)
        // crown-lab measurement hook (DEBUG only): `probe.likes` / `probe.bookmarks`.
        .crownProbe(kind.rawValue)
        .task(id: taskKey) {
            configure()
            await list.loadIfNeeded()
        }
        .swipeBack()
    }

    private var emptyText: String {
        kind == .likes ? "No likes yet." : "No bookmarks yet."
    }

    /// Includes the viewer id: Likes needs it, and AppModel loads it on its own, so the
    /// list reconfigures when it arrives instead of every screen fetching it.
    private var taskKey: String {
        "\(kind.rawValue)-\(app.isLoggedIn)-\(app.activeAccountId ?? "none")-\(app.viewer?.id ?? "")"
    }

    private func configure() {
        guard configuredKey != taskKey else { return }
        configuredKey = taskKey
        list.reset()
        let client = app.client
        let userId = app.activeAccount?.user?.id ?? app.viewer?.id

        switch kind {
        case .likes:
            list.fetch = { cursor in
                guard let userId, !userId.isEmpty else { throw XError.notLoggedIn }
                let p = try await client.likes(userId: userId, cursor: cursor)
                return (p.items, p.bottomCursor, p.topCursor)
            }
        case .bookmarks:
            list.fetch = { cursor in
                let p = try await client.bookmarks(cursor: cursor)
                return (p.items, p.bottomCursor, p.topCursor)
            }
        }
        list.onPage = { items in
            ImageLoader.shared.prefetchFeed(items.displayTweets)
        }
        list.skip = { $0.isFiller }
    }
}
