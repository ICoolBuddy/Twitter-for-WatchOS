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
                if list.isEmpty && list.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else if let e = list.error, list.isEmpty {
                    ErrorStateView(error: e) { await list.refresh() }
                        .padding(.vertical, 8)
                } else if list.isEmpty && !list.isLoading {
                    Text("No posts yet.")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                }

                ForEach(list.items) { item in
                    TimelineItemRows(item: item,
                                     onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                     onMedia: { mediaTarget = $0 })
                        .onAppear { list.loadMoreIfNeeded(current: item) }
                    PostSeparator()
                }

                if let e = list.error, !list.isEmpty {
                    Text(e.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
        }
        .background(Color.black)
        .navigationTitle("@" + user.screenName)
        .pullToRefresh(isRefreshing: list.isRefreshing) { await list.refresh() }
        .task(id: taskKey) {
            configure()
            await list.loadIfNeeded()
        }
        .postPresentation(profile: $profileTarget, media: $mediaTarget)
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
    }
}
