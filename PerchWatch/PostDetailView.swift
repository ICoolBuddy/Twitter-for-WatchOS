import SwiftUI
import XKit

/// Full post: ancestors, focal post (full text, all media, quote), then replies
/// that auto-load when scrolling near the bottom. The focal post is not a link
/// to itself.
struct PostDetailView: View {
    let tweet: XTweet
    @EnvironmentObject private var app: AppModel

    @State private var thread: ThreadPage?
    @State private var replies: [TimelineItem] = []
    @State private var cursor: String?
    @State private var error: XError?
    @State private var loading = false

    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?
    @ObservedObject private var saved = SavedStore.shared

    private var focal: XTweet { thread?.focal ?? tweet.displayed }
    private var ancestors: [XTweet] { thread?.ancestors ?? [] }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(ancestors) { a in
                    FeedPostView(tweet: a, compact: true, showActions: false,
                                 onOpenProfile: { profileTarget = ProfileTarget(user: $0) })
                    PostSeparator()
                }

                FeedPostView(tweet: focal,
                             showDate: true,
                             linkToPost: false,
                             clampLongText: false,
                             onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                             onMedia: { mediaTarget = $0 })

                if let error, replies.isEmpty {
                    ErrorStateView(error: error) { await load() }
                        .padding(.vertical, 8)
                }

                if !replies.isEmpty {
                    HStack(spacing: 6) {
                        Text("Replies")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if loading { ProgressView() }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }

                PostSeparator()

                if loading && replies.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }

                if replies.isEmpty, cursor != nil, !loading, focal.replyCount > 0 {
                    Button {
                        Task { await loadMore() }
                    } label: {
                        Text("Load replies")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                ForEach(replies) { item in
                    TimelineItemRows(item: item,
                                     onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                     onMedia: { mediaTarget = $0 })
                        .onAppear { prefetch(item) }
                    PostSeparator()
                }

                if let error, !replies.isEmpty {
                    Text(error.localizedDescription)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 4)
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
        }
        .background(Color.black)
        .navigationTitle("Post")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    saved.toggle(focal)
                } label: {
                    Image(systemName: saved.isSaved(focal.id) ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .accessibilityLabel(saved.isSaved(focal.id) ? "Remove from saved" : "Save for offline")
            }
        }
        .task {
            if thread == nil {
                seedFromCache()
                await load()
            }
        }
        .postPresentation(profile: $profileTarget, media: $mediaTarget)
        .swipeBack()
    }

    /// What was on screen last time this post was opened (offline support).
    private func seedFromCache() {
        guard thread == nil, let cached = OfflineCache.thread(id: tweet.displayed.id) else { return }
        thread = cached
        replies = cached.replies
        cursor = cached.bottomCursor
        ImageLoader.shared.prefetchFeed(cached.replies.displayTweets)
    }

    private func saveToCache() {
        let page = ThreadPage(focal: thread?.focal ?? tweet.displayed,
                              ancestors: thread?.ancestors ?? [],
                              replies: replies,
                              bottomCursor: cursor)
        OfflineCache.save(page, id: tweet.displayed.id)
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        do {
            let t = try await app.client.tweetDetail(id: tweet.displayed.id, cursor: nil)
            thread = t
            replies = t.replies
            cursor = t.bottomCursor
            OfflineCache.save(t, id: tweet.displayed.id)
            ImageLoader.shared.prefetchFeed(replies.displayTweets)
        } catch is CancellationError {
        } catch {
            // With a cached thread on screen this is not an error wall, just
            // "you are offline".
            if thread == nil { self.error = XError.from(error) }
        }
        loading = false
        // Replies auto-load: if the first page brought none, fetch the next one
        // (only when X says there are replies and there is a cursor).
        if replies.isEmpty, cursor != nil, focal.replyCount > 0 {
            await loadMore()
        }
    }

    /// Replies auto-load: called from each reply row's `onAppear`.
    private func prefetch(_ item: TimelineItem) {
        guard cursor != nil, !loading else { return }
        guard let idx = replies.firstIndex(where: { $0.id == item.id }) else { return }
        guard idx >= replies.count - 4 else { return }
        Task { await loadMore() }
    }

    private func loadMore() async {
        guard let c = cursor, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let t = try await app.client.tweetDetail(id: tweet.displayed.id, cursor: c)
            let ids = Set(replies.map(\.id))
            let fresh = t.replies.filter { !ids.contains($0.id) }
            replies.append(contentsOf: fresh)
            cursor = (t.bottomCursor == c || fresh.isEmpty) ? nil : t.bottomCursor
            saveToCache()
            ImageLoader.shared.prefetchFeed(t.replies.displayTweets)
        } catch is CancellationError {
        } catch {
            self.error = XError.from(error)
        }
    }
}
