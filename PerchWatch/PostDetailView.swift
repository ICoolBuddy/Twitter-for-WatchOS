import SwiftUI
import XKit

/// Full post: ancestors, focal post (full text, all media, quote), then replies
/// that auto-load when scrolling near the bottom.
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
    @State private var replyTarget: XTweet?

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
                             showBookmark: true,
                             showDate: true,
                             onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                             onMedia: { mediaTarget = $0 },
                             onReply: { replyTarget = $0 })

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

                if replies.isEmpty, cursor != nil, !loading {
                    Button("Load replies") { Task { await loadMore() } }
                        .font(.system(size: 13))
                        .padding(.vertical, 8)
                }

                ForEach(replies) { item in
                    TimelineItemRows(item: item,
                                     onOpenProfile: { profileTarget = ProfileTarget(user: $0) },
                                     onMedia: { mediaTarget = $0 },
                                     onReply: { replyTarget = $0 })
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
        .task { if thread == nil { await load() } }
        .postPresentation(profile: $profileTarget, media: $mediaTarget, reply: $replyTarget)
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let t = try await app.client.tweetDetail(id: tweet.displayed.id, cursor: nil)
            thread = t
            replies = t.replies
            cursor = t.bottomCursor
        } catch is CancellationError {
        } catch {
            self.error = XError.from(error)
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
        } catch is CancellationError {
        } catch {
            self.error = XError.from(error)
        }
    }
}
