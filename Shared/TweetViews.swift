import Foundation
import SwiftUI
import XKit

/// Navigation destinations shared by both apps.
enum Route: Hashable {
    case post(XTweet)
    case user(String)          // screen name
    case userId(String)
    case notifications
    case search
    case bookmarks
    case likes
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

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Avatar(user: tweet.author, size: avatarSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(tweet.author.name)
                        .font(nameFont)
                        .lineLimit(1)
                    if tweet.author.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.blue)
                            .accessibilityLabel("Verified")
                    }
                }
                HStack(spacing: 3) {
                    Text("@" + tweet.author.screenName).lineLimit(1)
                    if let d = tweet.createdAt {
                        Text("·")
                        Text(RelativeTime.short(d))
                    }
                }
                .font(metaFont)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
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

    private var ratio: CGFloat {
        #if os(watchOS)
        return CGFloat(media.aspectRatio)
        #else
        return max(0.75, min(CGFloat(media.aspectRatio), 2.2))
        #endif
    }

    private var cap: CGFloat? {
        #if os(watchOS)
        return maxHeight
        #else
        return maxHeight ?? Metrics.mediaMaxHeight
        #endif
    }

    var body: some View {
        RemoteImage(url: media.feedURL, placeholderURL: media.previewURL, maxPixel: Metrics.imagePixels)
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

/// The Parrot-style action row: reply / repost / like / share, evenly spaced.
/// Like and repost are optimistic (via `PostStateStore`) and give one subtle
/// haptic on an explicit tap.
struct PostActionRow: View {
    let tweet: XTweet
    var isTop = false
    var showBookmark = false
    var onReply: (() -> Void)? = nil

    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var posts: PostStateStore

    var body: some View {
        let s = posts.state(for: tweet)
        HStack(spacing: 0) {
            replyButton
            repostButton(s)
            likeButton(s)
            if showBookmark { bookmarkButton(s) }
            shareButton
        }
        .font(Metrics.actionFont)
        .foregroundStyle(.secondary)
    }

    private var replyButton: some View {
        Button {
            onReply?()
        } label: {
            glyph("bubble.left", active: false, color: .secondary, count: tweet.replyCount)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reply")
    }

    private func repostButton(_ s: PostStateStore.State) -> some View {
        Button {
            posts.toggleRetweet(tweet, client: app.client)
        } label: {
            glyph("arrow.2.squarepath", active: s.retweeted, color: .green, count: s.retweetCount)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.retweeted ? "Undo repost" : "Repost")
    }

    @ViewBuilder
    private func likeButton(_ s: PostStateStore.State) -> some View {
        #if os(watchOS)
        if isTop {
            baseLikeButton(s).handGestureShortcut(.primaryAction)
        } else {
            baseLikeButton(s)
        }
        #else
        baseLikeButton(s)
        #endif
    }

    private func baseLikeButton(_ s: PostStateStore.State) -> some View {
        Button {
            posts.toggleLike(tweet, client: app.client)
        } label: {
            glyph(s.liked ? "heart.fill" : "heart", active: s.liked, color: .pink, count: s.likeCount)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.liked ? "Unlike" : "Like")
    }

    private func bookmarkButton(_ s: PostStateStore.State) -> some View {
        Button {
            posts.toggleBookmark(tweet, client: app.client)
        } label: {
            glyph(s.bookmarked ? "bookmark.fill" : "bookmark", active: s.bookmarked, color: .blue, count: nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(s.bookmarked ? "Remove bookmark" : "Bookmark")
    }

    private var shareButton: some View {
        ShareLink(item: shareURL) {
            glyph("square.and.arrow.up", active: false, color: .secondary, count: nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Share")
    }

    private func glyph(_ name: String, active: Bool, color: Color, count: Int?) -> some View {
        HStack(spacing: 2) {
            Image(systemName: name)
            if let count, count > 0 {
                Text(count.compact)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .foregroundStyle(active ? color : Color.secondary)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var shareURL: URL {
        URL(string: "https://x.com/\(tweet.author.screenName)/status/\(tweet.id)")
            ?? URL(string: "https://x.com")!
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
                Button("Sync from iPhone") { app.sync?.syncNow(); message = "Requested…" }
                #else
                Text("Log in again from the Account section.").font(.caption).foregroundStyle(.secondary)
                #endif
            case .refreshEndpoints:
                Button(working ? "Refreshing…" : "Refresh endpoints") {
                    Task {
                        working = true
                        defer { working = false }
                        do {
                            try await app.refreshEndpoints()
                            message = "Updated."
                            await retry?()
                        } catch {
                            message = XError.from(error).localizedDescription
                        }
                    }
                }
                .disabled(working)
            case .wait:
                EmptyView()
            case .retry:
                if let retry { Button("Retry") { Task { await retry() } } }
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var icon: String {
        switch error.recovery {
        case .relogin: return "person.crop.circle.badge.exclamationmark"
        case .refreshEndpoints: return "arrow.triangle.2.circlepath"
        case .wait: return "hourglass"
        case .retry: return "wifi.exclamationmark"
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
            Button("Load more", action: action).frame(maxWidth: .infinity)
        }
    }
}
