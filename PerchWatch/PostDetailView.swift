import SwiftUI
import XKit

/// Full post: ancestors, focal post (full text, all images, quote), then replies.
struct PostDetailView: View {
    let tweet: XTweet
    @EnvironmentObject private var app: AppModel
    @State private var thread: ThreadPage?
    @State private var replies: [TimelineItem] = []
    @State private var cursor: String?
    @State private var error: XError?
    @State private var loading = false
    @State private var zoomMedia: XMedia?

    private var focal: XTweet { thread?.focal ?? tweet.displayed }

    var body: some View {
        List {
            if let ancestors = thread?.ancestors, !ancestors.isEmpty {
                ForEach(ancestors) { a in
                    NavigationLink(value: Route.post(a)) {
                        TweetRow(tweet: a, showCounts: false, lineLimit: 3).opacity(0.8)
                    }
                }
            }
            FocalPostView(tweet: focal) { zoomMedia = $0 }
                .listRowBackground(Color.clear)

            if let error {
                ErrorStateView(error: error) { await load() }
                    .listRowBackground(Color.clear)
            }
            if loading && replies.isEmpty {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if !replies.isEmpty {
                Text("Replies").font(.caption2.bold()).foregroundStyle(.secondary).listRowBackground(Color.clear)
            }
            ForEach(replies) { item in
                TimelineItemRows(item: item)
            }
            if cursor != nil {
                LoadMoreRow(isLoading: loading, reachedEnd: false) { Task { await loadMore() } }
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Post")
        .task { if thread == nil { await load() } }
        .sheet(item: $zoomMedia) { m in ImageZoomView(media: m) }
    }

    private func load() async {
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
        } catch {
            self.error = XError.from(error)
        }
    }
}

struct FocalPostView: View {
    let tweet: XTweet
    var onMedia: (XMedia) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NavigationLink(value: Route.user(tweet.author.screenName)) {
                TweetHeader(tweet: tweet)
            }
            .buttonStyle(.plain)
            if let to = tweet.inReplyToScreenName {
                Text("Replying to @\(to)").font(.caption2).foregroundStyle(.secondary)
            }
            Text(tweet.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(tweet.media) { m in
                Button { onMedia(m) } label: { MediaThumb(media: m) }
                    .buttonStyle(.plain)
            }
            if let q = tweet.quotedTweet?.value {
                NavigationLink(value: Route.post(q)) { QuotedTweetView(tweet: q) }
                    .buttonStyle(.plain)
            }
            if let d = tweet.createdAt {
                Text(d.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let v = tweet.viewCount { Text("\(v.compact) views").font(.caption2).foregroundStyle(.secondary) }
            CountsRow(tweet: tweet)
        }
    }
}

/// Full-screen image with Digital Crown zoom and drag to pan.
struct ImageZoomView: View {
    let media: XMedia
    @State private var zoom: Double = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            RemoteImage(url: media.imageURL(size: "medium"), maxPixel: 900, contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            offset = CGSize(width: dragStart.width + v.translation.width,
                                            height: dragStart.height + v.translation.height)
                        }
                        .onEnded { _ in dragStart = offset }
                )
                .onTapGesture(count: 2) {
                    withAnimation { zoom = 1; offset = .zero; dragStart = .zero }
                }
        }
        .focusable()
        .digitalCrownRotation($zoom, from: 1, through: 5, by: 0.1, sensitivity: .medium,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .ignoresSafeArea()
        .accessibilityLabel(media.altText ?? "Image")
    }
}
