import Foundation
import SwiftUI
import XKit

/// What to show in the full-screen media viewer.
struct MediaTarget: Identifiable {
    let media: [XMedia]
    let startIndex: Int
    /// Shown in Now Playing for videos: the author, and the post text.
    var title: String? = nil
    var caption: String? = nil
    var id: String { media.map(\.id).joined(separator: ",") + "-\(startIndex)" }
}

/// App-wide full-screen media presentation. The viewer is drawn as an overlay at
/// the root (`WatchRootView`) instead of a `fullScreenCover`, so it has no system
/// close button: we draw our own and can hide it with the rest of the chrome.
@MainActor
final class MediaPresenter: ObservableObject {
    static let shared = MediaPresenter()
    @Published private(set) var target: MediaTarget?
    /// Set for a moment before the viewer goes away: its pages give up crown
    /// focus first. A focused view that is simply removed leaves the crown
    /// pointing nowhere (it only came back after a finger scroll).
    @Published private(set) var closing = false

    func show(_ target: MediaTarget) {
        // A finger lifted over an image at the end of a page swipe.
        guard !SwipeGuard.isActive else { return }
        closing = false
        self.target = target
    }

    func close() {
        guard target != nil, !closing else { return }
        closing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            self.target = nil
            self.closing = false
        }
    }
}

/// Presents the profile sheet and routes media to the root overlay. Each screen
/// owns its own state so sheets never fight over a presenter. Replies use
/// `TextFieldLink` inside the action row, so there is no reply sheet.
struct PostPresentation: ViewModifier {
    @Binding var profile: ProfileTarget?
    @Binding var media: MediaTarget?

    @ObservedObject private var presenter = MediaPresenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $profile) { target in
                ProfileSheet(target: target)
            }
            .onChange(of: media?.id) { _, _ in
                guard let target = media else { return }
                media = nil
                presenter.show(target)
            }
    }
}

extension View {
    func postPresentation(profile: Binding<ProfileTarget?>,
                          media: Binding<MediaTarget?>) -> some View {
        modifier(PostPresentation(profile: profile, media: media))
    }
}

/// One post, Parrot style: big header, full-width media, action row.
/// Tapping the text (or the quote) opens the post page; tapping media opens the
/// media viewer; tapping the avatar or name opens the profile sheet.
struct FeedPostView: View {
    let tweet: XTweet
    var compact = false
    var showActions = true
    var showDate = false
    /// The focal post of the post page is not a link to itself.
    var linkToPost = true
    /// Long posts are collapsed to 14 lines with "Show more" in the feed; the
    /// post page shows its focal post in full.
    var clampLongText = true
    var onOpenProfile: ((XUser) -> Void)? = nil
    var onMedia: ((MediaTarget) -> Void)? = nil

    @State private var expanded = false
    @AppStorage(PerchSettings.textSize) private var textSizeRaw = PerchTextSize.medium.rawValue

    /// Settings → Text size, as a multiplier of the Parrot 19 pt body.
    private var textScale: CGFloat {
        (PerchTextSize(rawValue: textSizeRaw) ?? .medium).scale
    }

    private var t: XTweet { tweet.displayed }

    // Compact ancestors use smaller type; the feed itself uses the Parrot sizes.
    private var nameFont: Font { compact ? Font.system(size: 15, weight: .semibold) : Metrics.nameFont }
    private var metaFont: Font { compact ? Font.system(size: 12) : Metrics.metaFont }
    private var bodyFont: Font {
        compact ? .system(size: 15) : .system(size: 19 * textScale)
    }
    private var bannerFont: CGFloat { compact ? 12 : 13 }
    private var lineFont: CGFloat { (compact ? 12 : 13) * textScale }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            if tweet.isRetweet {
                Label("\(tweet.author.name) reposted", systemImage: "arrow.2.squarepath")
                    .font(.system(size: bannerFont))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if t.isTombstone {
                Text(t.tombstoneText ?? "Unavailable")
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                header
                if let to = t.inReplyToScreenName, t.inReplyToStatusId != nil {
                    Text("Replying to @\(to)")
                        .font(.system(size: lineFont))
                        .foregroundStyle(.secondary)
                }
                if !t.text.isEmpty { textBlock }
                if !compact, !t.media.isEmpty {
                    mediaBlock
                }
                if let q = t.quotedTweet?.value {
                    NavigationLink(value: Route.post(q)) {
                        QuotedTweetView(tweet: q)
                    }
                    .buttonStyle(.plain)
                }
                if showDate, !compact {
                    HStack(spacing: 5) {
                        if let d = t.createdAt {
                            Text(d.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let v = t.viewCount, v > 0 {
                            Text("·")
                            Text("\(v.compact) views")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                if showActions {
                    PostActionRow(tweet: t)
                }
            }
        }
        .padding(.vertical, compact ? 3 : 6)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                guard !SwipeGuard.isActive else { return }
                onOpenProfile?(t.author)
            } label: {
                Avatar(user: t.author, size: compact ? 28 : Metrics.avatar)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open @\(t.author.screenName) profile")

            VStack(alignment: .leading, spacing: 1) {
                Button {
                    guard !SwipeGuard.isActive else { return }
                onOpenProfile?(t.author)
                } label: {
                    HStack(spacing: 3) {
                        Text(t.author.name)
                            .font(nameFont)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if t.author.isVerified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.blue)
                                .accessibilityLabel("Verified")
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(t.author.name)'s profile")

                HStack(spacing: 3) {
                    // The handle gives way first: the time must stay readable on 41 mm.
                    Text("@" + t.author.screenName).lineLimit(1).truncationMode(.tail)
                    if let d = t.createdAt {
                        Text("· " + RelativeTime.short(d))
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(1)
                    }
                }
                .font(metaFont)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Media

    /// One attachment full width; 2–4 photos as a grid of square tiles (each
    /// opens the viewer on itself; a third photo gets a wide tile of its own)
    /// instead of the first one plus "+N".
    @ViewBuilder
    private var mediaBlock: some View {
        let media = t.media
        if media.count >= 2, media.allSatisfy({ $0.type == .photo }) {
            let shown = Array(media.prefix(4))
            let rows = stride(from: 0, to: shown.count, by: 2).map { Array(shown.indices[$0..<min($0 + 2, shown.count)]) }
            VStack(spacing: 3) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 3) {
                        ForEach(row, id: \.self) { index in
                            gridTile(media, index: index, wide: shown.count == 3 && index == 2)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Metrics.mediaCorner))
        } else if let m = media.first {
            Button {
                onMedia?(MediaTarget(media: media, startIndex: 0,
                                     title: t.author.name, caption: t.text))
            } label: {
                MediaThumb(media: m, extraCount: media.count - 1,
                           localURL: SavedStore.shared.localPhoto(tweetID: t.id, index: 0))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Open media")
        }
    }

    private func gridTile(_ media: [XMedia], index: Int, wide: Bool) -> some View {
        let m = media[index]
        let local = SavedStore.shared.localPhoto(tweetID: t.id, index: index)
        return Button {
            onMedia?(MediaTarget(media: media, startIndex: index,
                                 title: t.author.name, caption: t.text))
        } label: {
            Color.clear
                .aspectRatio(wide ? 2 : 1, contentMode: .fit)
                .overlay {
                    RemoteImage(url: local ?? m.feedURL, placeholderURL: m.previewURL,
                                maxPixel: local != nil ? 400 : 300)
                }
                .clipped()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(m.altText ?? "Image \(index + 1) of \(media.count)")
    }

    // MARK: Text

    /// Longer than 500 characters or about 14 lines (we cannot measure lines in
    /// SwiftUI, so estimate from the character count per line, which shrinks
    /// with the Text size setting).
    private var isLong: Bool {
        if t.text.count > 500 { return true }
        let perLine = max(10, Int((20 / textScale).rounded()))
        var lines = 0
        for line in t.text.components(separatedBy: "\n") {
            lines += max(1, (line.count + perLine - 1) / perLine)
        }
        return lines > 14
    }

    private var isClamped: Bool { clampLongText && isLong && !expanded }

    @ViewBuilder
    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            textView
            if isClamped {
                showMoreButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Small outlined capsule under a clamped post: the plain text button was
    /// impossible to tell from a link.
    private var showMoreButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { expanded = true }
        } label: {
            HStack(spacing: 3) {
                Text("Show more")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Show more of this post")
    }

    @ViewBuilder
    private var textView: some View {
        if linkToPost {
            NavigationLink(value: Route.post(t)) {
                textBody
            }
            .buttonStyle(.plain)
        } else {
            textBody
        }
    }

    private var textBody: some View {
        Text(t.text)
            .font(bodyFont)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(isClamped ? 14 : nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// One timeline item: a single post, or a short conversation (thread) shown as
/// consecutive posts.
struct TimelineItemRows: View {
    let item: TimelineItem
    var compact = false
    var onOpenProfile: ((XUser) -> Void)? = nil
    var onMedia: ((MediaTarget) -> Void)? = nil

    var body: some View {
        switch item {
        case .tweet(let t):
            FeedPostView(tweet: t, compact: compact,
                         onOpenProfile: onOpenProfile, onMedia: onMedia)
        case .conversation(let ts):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ts.enumerated()), id: \.element.id) { idx, t in
                    FeedPostView(tweet: t, compact: compact,
                                 onOpenProfile: onOpenProfile, onMedia: onMedia)
                    if idx < ts.count - 1 { PostSeparator() }
                }
            }
        case .user(let u):
            Button {
                guard !SwipeGuard.isActive else { return }
                onOpenProfile?(u)
            } label: {
                UserRow(user: u)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 6)
        }
    }
}
