import Foundation
import SwiftUI
import XKit
#if os(watchOS)
import WatchKit
#endif

/// A relative timestamp that stays true while the row is on screen (a plain
/// `Text(RelativeTime.short(date))` froze at "3m" for as long as it was visible).
struct RelativeTimeText: View {
    let date: Date
    var prefix: String = ""

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(prefix + RelativeTime.short(date))
        }
    }
}

/// Navigation destinations shared by both apps.
/// Navigation payload whose identity is its id. `Route` values are NavigationLink
/// values (Hashable): hashing a whole post/user meant the route changed whenever a like
/// count or follower count did, while the link sat in the view tree.
struct IdentifiedRoute<Value: Identifiable>: Hashable {
    let value: Value
    init(_ value: Value) { self.value = value }
    static func == (l: Self, r: Self) -> Bool { l.value.id == r.value.id }
    func hash(into h: inout Hasher) { h.combine(value.id) }
}

enum Route: Hashable {
    case post(IdentifiedRoute<XTweet>)
    case user(String)          // screen name
    case userId(String)
    /// A user's posts as a feed (notification digests such as "new posts from @x").
    case userFeed(IdentifiedRoute<XUser>)
    case notifications
    case search
    case bookmarks
    case likes
    case saved
    case messages
    case conversation(DMConversation)
    case settings
    case debugLog
    case profileMe
}

/// Sizes and fonts. The Watch feed follows the Parrot look: big 19 pt text,
/// 44 pt avatars, no grey platters; the iPhone keeps a denser list style.
enum Metrics {
    #if os(watchOS)
    static let avatar: CGFloat = 44
    static let mediaMaxHeight: CGFloat = 260
    static let imagePixels = 450
    static let nameFont: Font = .system(size: 17, weight: .bold)
    static let metaFont: Font = .system(size: 15)
    static let bodyFont: Font = .system(size: 19)
    static let actionFont: Font = .system(size: 16)
    static let mediaCorner: CGFloat = 12
    static let horizontalPadding: CGFloat = 4
    #else
    static let avatar: CGFloat = 40
    static let mediaMaxHeight: CGFloat = 260
    static let imagePixels = 900
    static let nameFont: Font = .subheadline.weight(.semibold)
    static let metaFont: Font = .caption
    static let bodyFont: Font = .body
    static let actionFont: Font = .system(size: 15)
    static let mediaCorner: CGFloat = 10
    static let horizontalPadding: CGFloat = 16
    #endif
}

struct TweetHeader: View {
    let tweet: XTweet
    var avatarSize: CGFloat = Metrics.avatar
    var nameFont: Font = Metrics.nameFont
    var metaFont: Font = Metrics.metaFont
    #if os(watchOS)
    @AppStorage(PerchSettings.textSize) private var textSizeRaw = PerchTextSize.medium.rawValue

    private var textScale: CGFloat {
        (PerchTextSize(rawValue: textSizeRaw) ?? .medium).scale
    }

    private var watchNameFont: Font {
        .system(size: 17 * textScale, weight: .bold)
    }

    private var watchMetaFont: Font {
        .system(size: 15 * textScale)
    }
    #endif

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Avatar(user: tweet.author, size: avatarSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(tweet.author.name)
                        .font(headerNameFont)
                        .lineLimit(1)
                    if tweet.author.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Verified")
                    }
                }
                HStack(spacing: 3) {
                    Text("@" + tweet.author.screenName).lineLimit(1).truncationMode(.tail)
                    if let d = tweet.createdAt {
                        RelativeTimeText(date: d, prefix: "· ")
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                .font(headerMetaFont)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var headerNameFont: Font {
        #if os(watchOS)
        return watchNameFont
        #else
        return nameFont
        #endif
    }

    private var headerMetaFont: Font {
        #if os(watchOS)
        return watchMetaFont
        #else
        return metaFont
        #endif
    }
}

/// A post in the iPhone fallback list: repost banner, header, text, first media,
/// quote, counts. The Watch uses `FeedPostView` instead.
struct TweetRow: View {
    let tweet: XTweet
    var showCounts = true
    var lineLimit: Int? = nil

    var body: some View {
        let t = tweet.displayed
        VStack(alignment: .leading, spacing: 4) {
            if tweet.isRetweet {
                Label("\(tweet.author.name) reposted", systemImage: "arrow.2.squarepath")
                    .font(Metrics.metaFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if t.isTombstone {
                Text(t.tombstoneText ?? "Unavailable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                TweetHeader(tweet: t)
                if let to = t.inReplyToScreenName, t.inReplyToStatusId != nil {
                    Text("Replying to @\(to)")
                        .font(Metrics.metaFont)
                        .foregroundStyle(.secondary)
                }
                if !t.text.isEmpty {
                    Text(t.text)
                        .font(Metrics.bodyFont)
                        .lineLimit(lineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let m = t.media.first {
                    MediaThumb(media: m, extraCount: t.media.count - 1)
                }
                if let q = t.quotedTweet?.value {
                    QuotedTweetView(tweet: q)
                }
                if showCounts { CountsRow(tweet: t) }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Full-width media. On the Watch the height follows the media's own aspect
/// ratio with no cap (a tall screenshot is shown in full); on the iPhone tall
/// media is capped so the list stays scrollable.
struct MediaThumb: View {
    let media: XMedia
    var extraCount = 0
    var maxHeight: CGFloat? = nil
    /// A locally saved copy of this media, preferred over the network.
    var localURL: URL? = nil

    private var ratio: CGFloat {
        #if os(watchOS)
        return max(0.05, CGFloat(media.aspectRatio))
        #else
        return max(0.75, min(CGFloat(media.aspectRatio), 2.2))
        #endif
    }

    private var cap: CGFloat? {
        #if os(watchOS)
        // Absurdly tall images (long screenshots) would otherwise be many screens
        // high: scale them to fit, centred, and keep the aspect. Normal phone
        // screenshots (ratio >= 0.45) stay full width. Callers that asked for a
        // small cap (quotes, notifications) keep it.
        if maxHeight == nil, media.aspectRatio < 0.45 {
            return WKInterfaceDevice.current().screenBounds.height * 1.3
        }
        return maxHeight
        #else
        return maxHeight ?? Metrics.mediaMaxHeight
        #endif
    }

    #if os(watchOS)
    /// Same URL + decode size the prefetcher warms, so the feed hits the memory cache. A
    /// capped thumbnail (quote, notification: 80–90 pt tall) decodes smaller: the feed
    /// size of a tall screenshot is up to 1400 px, megabytes of the 24 MB cache. Same URL,
    /// so the disk cache is still shared.
    private var image: (url: URL, maxPixel: Int) {
        let base = ImageLoader.feedImage(for: media)
        guard let maxHeight else { return base }
        return (base.url, min(base.maxPixel, max(200, Int(maxHeight * 2.5))))
    }
    #else
    /// Tall images (screenshots) are shown full width, so their long side needs far more
    /// pixels than a landscape photo: use X's 1200 px "medium" and decode at width / ratio.
    private var isTall: Bool { media.aspectRatio < 0.9 }
    private var image: (url: URL, maxPixel: Int) {
        let pixels = isTall
            ? min(1400, Int(Double(Metrics.imagePixels) / max(media.aspectRatio, 0.3)))
            : Metrics.imagePixels
        return (isTall ? media.fullURL : media.feedURL, pixels)
    }
    #endif

    var body: some View {
        RemoteImage(url: localURL ?? image.url, placeholderURL: media.previewURL,
                    maxPixel: localURL != nil ? 600 : image.maxPixel)
            .aspectRatio(ratio, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: cap)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.mediaCorner))
            .overlay(alignment: .center) {
                if media.type != .photo {
                    Image(systemName: "play.circle")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .shadow(radius: 3)
                        .accessibilityLabel("Video")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if extraCount > 0 {
                    Text("+\(extraCount)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(4)
                }
            }
            .accessibilityLabel(media.altText ?? (media.type == .photo ? "Image" : "Video"))
    }
}

struct QuotedTweetView: View {
    let tweet: XTweet

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(tweet.author.name).font(Metrics.metaFont.weight(.semibold)).lineLimit(1)
                Text("@" + tweet.author.screenName).font(Metrics.metaFont).foregroundStyle(.secondary).lineLimit(1)
            }
            if tweet.isTombstone {
                Text(tweet.tombstoneText ?? "").font(.footnote).foregroundStyle(.secondary)
            } else {
                Text(tweet.text).font(.footnote).lineLimit(4)
                if let m = tweet.media.first { MediaThumb(media: m, maxHeight: 80) }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
    }
}

/// Non-interactive counts, used by the iPhone fallback list.
struct CountsRow: View {
    let tweet: XTweet
    @EnvironmentObject private var posts: PostStateStore

    var body: some View {
        let s = posts.state(for: tweet)
        HStack(spacing: 0) {
            count("bubble.left", tweet.replyCount, active: false, color: .blue)
            count("arrow.2.squarepath", s.retweetCount, active: s.retweeted, color: .green)
            count(s.liked ? "heart.fill" : "heart", s.likeCount, active: s.liked, color: .pink)
            if s.bookmarked {
                Image(systemName: "bookmark.fill").foregroundStyle(.blue)
            }
        }
        .font(Metrics.metaFont)
        .foregroundStyle(.secondary)
    }

    private func count(_ icon: String, _ n: Int, active: Bool, color: Color) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
            Text(n > 0 ? n.compact : "")
        }
        .foregroundStyle(active ? color : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Parrot-style action row: reply / repost / like / bookmark, four evenly
/// spaced quarters with the glyph and count centred in each. Reply opens the
/// system text input directly (`TextFieldLink`) and reports "Sent" / "Failed"
/// inline — no sheet. Like and repost are optimistic (via `PostStateStore`).
struct PostActionRow: View {
    let tweet: XTweet

    // Not AppModel: observing it re-rendered every visible row on unrelated changes
    // (badge, busy message). The store carries the client.
    @EnvironmentObject private var posts: PostStateStore

    @State private var sendingReply = false
    @State private var replyStatus: String?
    @State private var statusToken = 0
    /// The text of a reply that failed, kept so it can be sent again instead of
    /// making the reader dictate it twice.
    @State private var failedReply: String?
    /// Replies sent from this row (the count from X lags behind).
    @State private var sentReplies = 0

    var body: some View {
        let s = posts.state(for: tweet)
        VStack(spacing: 2) {
            HStack(spacing: 0) {
                replyButton
                repostButton(s)
                likeButton(s)
                bookmarkButton(s)
            }
            .font(Metrics.actionFont)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)

            if let failedReply, !sendingReply {
                Button {
                    send(failedReply)
                } label: {
                    Label("Reply failed. Tap to retry", systemImage: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.swipeSafe)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
            } else if let replyStatus {
                Text(replyStatus)
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .accessibilityLabel(replyStatus)
            }
        }
    }

    @ViewBuilder
    private var replyButton: some View {
        #if os(watchOS)
        TextFieldLink(prompt: Text("Reply"), label: {
            glyph("bubble.left", active: false, color: .secondary, count: tweet.replyCount + sentReplies)
        }, onSubmit: { text in
            send(text)
        })
        .buttonStyle(.swipeSafe)
        .frame(maxWidth: .infinity)
        .disabled(sendingReply)
        .accessibilityLabel("Reply")
        #else
        // TextFieldLink is watchOS-only and the iPhone has no reply composer: show the
        // count, not a button that does nothing.
        glyph("bubble.left", active: false, color: .secondary, count: tweet.replyCount + sentReplies)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("\(tweet.replyCount + sentReplies) replies")
        #endif
    }

    private func repostButton(_ s: PostStateStore.State) -> some View {
        Button {
            posts.toggleRetweet(tweet)
        } label: {
            glyph("arrow.2.squarepath", active: s.retweeted, color: .green, count: s.retweetCount)
        }
        .buttonStyle(.swipeSafe)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(s.retweeted ? "Undo repost" : "Repost")
    }

    private func likeButton(_ s: PostStateStore.State) -> some View {
        Button {
            posts.toggleLike(tweet)
        } label: {
            glyph(s.liked ? "heart.fill" : "heart", active: s.liked, color: .pink, count: s.likeCount)
        }
        .buttonStyle(.swipeSafe)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(s.liked ? "Unlike" : "Like")
    }

    private func bookmarkButton(_ s: PostStateStore.State) -> some View {
        Button {
            posts.toggleBookmark(tweet)
        } label: {
            glyph(s.bookmarked ? "bookmark.fill" : "bookmark", active: s.bookmarked, color: .blue, count: nil)
        }
        .buttonStyle(.swipeSafe)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(s.bookmarked ? "Remove bookmark" : "Bookmark")
    }

    private func glyph(_ name: String, active: Bool, color: Color, count: Int?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: name)
                .font(.system(size: 17))
                .frame(height: 19)
            if let count, count > 0 {
                // Bounded and shrinkable: long counts ("999K", "1.2M") used to
                // push past their quarter and overlap the neighbouring action.
                Text(count.compact)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(maxWidth: 30, alignment: .leading)
            }
        }
        .foregroundStyle(active ? color : Color.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .contentShape(Rectangle())
    }

    /// Sends the reply right away; the keyboard/dictation is the system one opened
    /// by `TextFieldLink`. The result is a small label under the row for ~2 s.
    private func send(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !sendingReply, let client = posts.client else { return }
        let replyTo = tweet.id
        sendingReply = true
        statusToken += 1
        let token = statusToken
        replyStatus = "Sending…"
        Task {
            do {
                _ = try await client.createTweet(text: body, replyTo: replyTo)
                Haptics.success()
                sendingReply = false
                failedReply = nil
                sentReplies += 1
                withAnimation(.easeOut(duration: 0.15)) { replyStatus = "Sent" }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if statusToken == token {
                    withAnimation(.easeOut(duration: 0.15)) { replyStatus = nil }
                }
            } catch {
                Haptics.failure()
                sendingReply = false
                // Keep the text: the row turns into a retry button until it works.
                withAnimation(.easeOut(duration: 0.15)) {
                    replyStatus = nil
                    failedReply = body
                }
            }
        }
    }
}

/// 0.5 pt hairline between posts.
struct PostSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(height: 0.5)
    }
}

struct UserRow: View {
    let user: XUser

    var body: some View {
        HStack(spacing: 6) {
            Avatar(user: user, size: Metrics.avatar)
            VStack(alignment: .leading, spacing: 0) {
                Text(user.name).font(Metrics.nameFont).lineLimit(1)
                Text("@" + user.screenName).font(Metrics.metaFont).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Full-screen error with the right recovery action for each failure type.
struct ErrorStateView: View {
    let error: XError
    var retry: (() async -> Void)?
    @EnvironmentObject private var app: AppModel
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.orange)
            Text(error.localizedDescription)
                .font(.footnote)
                .multilineTextAlignment(.center)
            if let message {
                Text(message).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            switch error.recovery {
            case .relogin:
                #if os(watchOS)
                Text("Open Perch on your iPhone and log in again.")
                    .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Sync from iPhone", action: SwipeGuard.run {
                    app.sync?.syncNow()
                    // The channel's own status, not "Requested…": it may not have asked.
                    message = app.sync?.statusText
                })
                    .frame(maxWidth: .infinity)
                #else
                Text("Log in again from the Account section.").font(.caption).foregroundStyle(.secondary)
                #endif
            // One remedy per error: XKit decided which one fits (`XError.recovery`).
            case .refreshEndpoints:
                Button(working ? "Refreshing…" : "Refresh endpoints", action: SwipeGuard.run {
                    recover { try await app.refreshEndpoints() }
                })
                .frame(maxWidth: .infinity)
                .disabled(working)
            case .refreshMaterial:
                Button(working ? "Renewing…" : "Renew signing key", action: SwipeGuard.run {
                    recover { try await app.refreshMaterial() }
                })
                .frame(maxWidth: .infinity)
                .disabled(working)
            case .wait:
                EmptyView()
            case .retry:
                if let retry {
                    Button("Retry", action: SwipeGuard.run {
                        Task { await retry() }
                    })
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    /// Runs a remedy, then retries the failed load.
    private func recover(_ remedy: @escaping @MainActor () async throws -> Void) {
        Task {
            working = true
            defer { working = false }
            do {
                try await remedy()
                message = "Updated."
                await retry?()
            } catch {
                message = XError.from(error).localizedDescription
            }
        }
    }

    private var icon: String {
        switch error.recovery {
        case .relogin: return "person.crop.circle.badge.exclamationmark"
        case .refreshEndpoints: return "arrow.triangle.2.circlepath"
        case .refreshMaterial: return "key"
        case .wait: return "hourglass"
        case .retry: return "wifi.exclamationmark"
        }
    }
}

/// Bottom of an infinitely scrolling list, read from the list's own state: a spinner
/// while the next page loads, the error with Retry after a failed page (paging used to
/// stop silently after one network blip), and a visible end once there is nothing more
/// (X has no older posts, or paging stopped at the memory cap).
struct PagingFooter<Item: Identifiable & Hashable>: View {
    @ObservedObject var list: PagedList<Item>

    var body: some View {
        if list.phase == .paging {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        } else if let error = list.error, !list.isEmpty {
            VStack(spacing: 4) {
                Text(error.localizedDescription)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button {
                    list.retryMore()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.swipeSafe)
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } else if list.showsEnd {
            VStack(spacing: 2) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 14))
                Text("That's everything")
                    .font(.system(size: 12, weight: .semibold))
                if list.stoppedAtCap {
                    Text("Pull down at the top for newer posts.")
                        .font(.system(size: 11))
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .accessibilityElement(children: .combine)
        }
    }
}

struct LoadMoreRow: View {
    let isLoading: Bool
    let reachedEnd: Bool
    let action: () -> Void

    var body: some View {
        if isLoading {
            ProgressView().frame(maxWidth: .infinity)
        } else if !reachedEnd {
            Button("Load more", action: SwipeGuard.run {
                action()
            })
            .frame(maxWidth: .infinity)
        }
    }
}
