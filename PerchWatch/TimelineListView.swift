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
                if list.isEmpty && list.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                } else if let e = list.error, list.isEmpty {
                    ErrorStateView(error: e) { await list.refresh() }
                        .padding(.vertical, 8)
                } else if list.isEmpty && !list.isLoading {
                    Text(emptyText)
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

                if list.isLoading && !list.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
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
        .navigationTitle(title)
        .pullToRefresh(isRefreshing: list.isRefreshing) { await list.refresh() }
        .task(id: taskKey) {
            await app.loadViewer()
            configure()
            await list.loadIfNeeded()
        }
        .postPresentation(profile: $profileTarget, media: $mediaTarget)
    }

    private var emptyText: String {
        kind == .likes ? "No likes yet." : "No bookmarks yet."
    }

    private var taskKey: String {
        "\(kind.rawValue)-\(app.isLoggedIn)-\(app.activeAccountId ?? "none")"
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
    }
}
