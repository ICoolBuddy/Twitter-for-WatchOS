import SwiftUI
import XKit

/// One user's recent posts as a plain feed. Opened from a "new post
/// notifications from @user" notification, which has no single tweet of its own:
/// it shows every post that account published (what the digest is about).
struct UserFeedView: View {
    let user: XUser

    @EnvironmentObject private var app: AppModel
    @StateObject private var list = PagedList<TimelineItem>(maxItems: 200, fetch: { _ in ([], nil, nil) })
    @State private var configuredFor: String?
    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    private var taskKey: String {
        "\(user.id)-\(app.isLoggedIn)-\(app.activeAccountId ?? "none")"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PagedListStatus(list: list, emptyText: "No posts yet.")

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
        .navigationTitle("@" + user.screenName)
        .task(id: taskKey) {
            configure()
            await list.loadIfNeeded()
        }
        .swipeBack()
    }

    private func configure() {
        guard configuredFor != taskKey else { return }
        configuredFor = taskKey
        list.reset()
        let client = app.client
        let userId = user.id
        list.fetch = { cursor in
            let p = try await client.userTweets(userId: userId, includeReplies: false, cursor: cursor)
            return (p.items, p.bottomCursor, p.topCursor)
        }
        list.onPage = { items in
            ImageLoader.shared.prefetchFeed(items.displayTweets)
        }
        list.skip = { $0.isFiller }
    }
}
