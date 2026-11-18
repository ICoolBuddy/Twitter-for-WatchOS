import SwiftUI
import XKit

/// Full post: ancestors, focal post (full text, all media, quote), then replies that
/// auto-load when scrolling near the bottom. The focal post is not a link to itself.
///
/// Replies page through the same `PagedList` as every other list (retry, end of list,
/// generation guard), instead of a hand-written copy of it that had drifted (a failed
/// reply page had no Retry, and a cached thread got the full error wall).
struct PostDetailView: View {
    let tweet: XTweet
    @EnvironmentObject private var app: AppModel

    /// The thread head (focal + ancestors) of the first page; replies live in `list`.
    @StateObject private var head = ThreadHead()
    @StateObject private var list = PagedList<TimelineItem>(maxItems: 300, fetch: { _ in ([], nil, nil) })
    @State private var configured = false

    @State private var profileTarget: ProfileTarget?
    @State private var mediaTarget: MediaTarget?

    private var focal: XTweet { head.thread?.focal ?? tweet.displayed }
    private var ancestors: [XTweet] { head.thread?.ancestors ?? [] }

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

                // Only a first load with nothing to show (no cached thread) is an error
                // wall; with a cached thread a failure is the footer's "message + Retry".
                if case .failed(let e) = list.phase, head.thread == nil {
                    ErrorStateView(error: e) { await list.refresh() }
                        .padding(.vertical, 8)
                }

                if !list.isEmpty {
                    HStack(spacing: 6) {
                        Text("Replies")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        if list.isRefreshing { ProgressView() }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }

                PostSeparator()

                if list.isEmpty, list.isFetching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                }

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
        .background(Color.black)
        .navigationTitle("Post")
        // crown-lab measurement hook (DEBUG only): `probe.post`.
        .crownProbe("post")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { SaveButton(tweet: focal) }
        }
        .task {
            guard !configured else { return }
            configured = true
            configure()
            // What was on screen last time this post was opened (offline support).
            if let cached = await OfflineCache.thread(id: tweet.displayed.id) {
                if head.thread == nil { head.thread = cached }
                list.seed(cached.replies)
            }
            await list.refresh(merge: !list.isEmpty)
        }
        .postPresentation(profile: $profileTarget, media: $mediaTarget)
        .swipeBack()
    }

    private func configure() {
        let client = app.client
        let id = tweet.displayed.id
        let replyCount = tweet.displayed.replyCount
        let head = self.head
        list.fetch = { cursor in
            var page = try await client.tweetDetail(id: id, cursor: cursor)
            if cursor == nil {
                await MainActor.run { head.thread = page }
                // X sometimes answers the first page with no replies but a cursor:
                // follow it once, so "Load replies" is never a manual step.
                if page.replies.isEmpty, replyCount > 0, let next = page.bottomCursor {
                    let more = try await client.tweetDetail(id: id, cursor: next)
                    page.replies = more.replies
                    page.bottomCursor = more.bottomCursor == next ? nil : more.bottomCursor
                }
            }
            return (page.replies, page.bottomCursor, nil)
        }
        let fallbackFocal = tweet.displayed
        // `weak`: the list keeps these closures, so a strong capture would leak it.
        list.onPage = { [weak list = self.list] items in
            ImageLoader.shared.prefetchFeed(items.displayTweets)
            // Keep the offline copy current with every page (encoded off the main thread).
            guard let list, head.thread != nil else { return }
            OfflineCache.save(ThreadPage(focal: head.thread?.focal ?? fallbackFocal,
                                         ancestors: head.thread?.ancestors ?? [],
                                         replies: list.items, bottomCursor: nil), id: id)
        }
    }
}

/// The thread head of a post page, set from the first reply page's fetch.
@MainActor
final class ThreadHead: ObservableObject {
    @Published var thread: ThreadPage?
}

/// Only this button observes the saved store: as an `@ObservedObject` of the whole post
/// screen, every attachment write re-rendered the thread and all its replies.
private struct SaveButton: View {
    let tweet: XTweet
    @ObservedObject private var saved = SavedStore.shared

    var body: some View {
        Button(action: SwipeGuard.run {
            saved.toggle(tweet)
        }) {
            Image(systemName: saved.isSaved(tweet.id) ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
        .accessibilityLabel(saved.isSaved(tweet.id) ? "Remove from saved" : "Save for offline")
    }
}
