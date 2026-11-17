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
    case messages
    case conversation(DMConversation)
    case settings
    case debugLog
    case profileMe
}

enum Metrics {
    #if os(watchOS)
    static let avatar: CGFloat = 22
    static let mediaMaxHeight: CGFloat = 110
    static let imagePixels = 360
    static let nameFont: Font = .footnote.weight(.semibold)
    static let metaFont: Font = .caption2
    static let bodyFont: Font = .body
    #else
    static let avatar: CGFloat = 40
    static let mediaMaxHeight: CGFloat = 260
    static let imagePixels = 900
    static let nameFont: Font = .subheadline.weight(.semibold)
    static let metaFont: Font = .caption
    static let bodyFont: Font = .body
    #endif
}

struct TweetHeader: View {
    let tweet: XTweet

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            Avatar(user: tweet.author, size: Metrics.avatar)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 2) {
                    Text(tweet.author.name)
                        .font(Metrics.nameFont)
                        .lineLimit(1)
                    if tweet.author.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
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
                .font(Metrics.metaFont)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A post in a list: repost banner, header, text, first media, quote, counts.
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

struct MediaThumb: View {
    let media: XMedia
    var extraCount = 0

    var body: some View {
        RemoteImage(url: media.thumbnailURL, maxPixel: Metrics.imagePixels)
            .aspectRatio(max(0.75, min(media.aspectRatio, 2.2)), contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: Metrics.mediaMaxHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .center) {
                if media.type != .photo {
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 2)
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
                if let m = tweet.media.first { MediaThumb(media: m).frame(maxHeight: 70) }
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
    }
}

struct CountsRow: View {
    let tweet: XTweet
    @EnvironmentObject private var posts: PostStateStore

    var body: some View {
        let s = posts.state(for: tweet)
        HStack(spacing: 0) {
            count("bubble.left", tweet.replyCount, active: false, color: .blue)
            count(s.retweeted ? "arrow.2.squarepath" : "arrow.2.squarepath", s.retweetCount, active: s.retweeted, color: .green)
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
        .foregroundStyle(active ? color : .secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UserRow: View {
    let user: XUser

    var body: some View {
        HStack(spacing: 6) {
            Avatar(user: user, size: Metrics.avatar + 4)
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
