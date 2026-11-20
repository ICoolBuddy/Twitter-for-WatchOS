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

/// App-wide full-screen media presentation. The viewer is drawn by a `MediaHost`
/// above whatever presentation context is on screen (the root, or a sheet), not
/// by a `fullScreenCover`, so it has no system close button: we draw our own and
/// can hide it with the rest of the chrome.
@MainActor
final class MediaPresenter: ObservableObject {
    static let shared = MediaPresenter()
    @Published private(set) var target: MediaTarget?
    /// True from the start of a present/dismiss until its transition is complete.
    /// Screens hold the crown while it is true (no timers): a focused view that
    /// is simply removed leaves the crown pointing nowhere.
    @Published private(set) var isTransitioning = false
    /// How many sheets are above the root. Exactly one `MediaHost` draws at a
    /// time (a video would otherwise play twice).
    @Published private(set) var sheetDepth = 0

    func show(_ target: MediaTarget) {
        // A finger lifted over an image at the end of a page swipe.
        guard !SwipeGuard.isActive else { return }
        guard self.target == nil else { return }
        beginTransition()
        withAnimation(.easeInOut(duration: 0.18), completionCriteria: .logicallyComplete) {
            self.target = target
        } completion: {
            self.endTransition()
        }
    }

    func close() {
        guard target != nil else { return }
        // The viewer marks itself closing for good on the first close, so a close
        // during the open animation must not be dropped (it locked the viewer).
        guard !isTransitioning else {
            pendingClose = true
            return
        }
        pendingClose = false
        beginTransition()
        withAnimation(.easeInOut(duration: 0.18), completionCriteria: .logicallyComplete) {
            self.target = nil
        } completion: {
            self.endTransition()
        }
    }

    /// Screens hold the crown while a transition runs, so a completion that never
    /// arrives would leave the crown dead. The animation is 0.18 s; this is the
    /// belt to its braces.
    private func beginTransition() {
        isTransitioning = true
        transitionSafety?.cancel()
        transitionSafety = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.endTransition()
        }
    }

    /// A close asked for while a transition ran.
    private var pendingClose = false

    private func endTransition() {
        guard isTransitioning else { return }
        isTransitioning = false
        transitionSafety?.cancel()
        if pendingClose { close() }
    }

    private var transitionSafety: Task<Void, Never>?

    func sheetOpened() { sheetDepth += 1 }
    /// The sheet's own bookkeeping can miss a dismissal (a push/pop under it); a stale
    /// depth leaves the media viewer undrawable until relaunch. The root clears it.
    func resetSheetDepth() { sheetDepth = 0 }
    func sheetClosed() { sheetDepth = max(0, sheetDepth - 1) }
}

/// Draws the one media viewer above whatever this presentation context shows.
/// Placed at the root and inside every sheet; the state is the same
/// `MediaPresenter`, so the chrome, the close button and the crown handoff
/// cannot drift between contexts.
struct MediaHost: View {
    /// True for the root copy: it only draws while no sheet is above it.
    var root = false
    @ObservedObject private var presenter = MediaPresenter.shared

    var body: some View {
        if let target = presenter.target,
           (root ? presenter.sheetDepth == 0 : presenter.sheetDepth > 0) {
            MediaViewer(media: target.media, startIndex: target.startIndex,
                        title: target.title, caption: target.caption,
                        onClose: { presenter.close() })
                .transition(.opacity)
                .zIndex(1)
                .ignoresSafeArea()
        }
    }
}

/// Presents the profile sheet and routes media to the media host. Each screen
/// owns its own state so sheets never fight over a presenter. Replies use
/// `TextFieldLink` inside the action row, so there is no reply sheet.
///
/// Inside a sheet a profile is *pushed* (`\.pushProfile`) instead of presenting
/// a second sheet: two stacked sheets would each draw a media host.
struct PostPresentation: ViewModifier {
    @Binding var profile: ProfileTarget?
    @Binding var media: MediaTarget?

    @Environment(\.pushProfile) private var pushProfile
    @ObservedObject private var presenter = MediaPresenter.shared

    func body(content: Content) -> some View {
        content
            // nil when this screen pushes profiles: no second sheet.
            .sheet(item: (pushProfile == nil) ? $profile : .constant(ProfileTarget?.none)) { target in
                ProfileSheet(target: target)
                    .onAppear { presenter.sheetOpened() }
                    .onDisappear { presenter.sheetClosed() }
            }
            .onChange(of: profile?.id) { _, _ in
                guard let target = profile, let pushProfile else { return }
                profile = nil
                pushProfile(target)
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
                // The long-text estimate scans the string: once per body pass.
                if !t.text.isEmpty { textBlock(clamped: isClamped) }
                if !compact, !t.media.isEmpty {
                    mediaBlock
                }
                if let q = t.quotedTweet?.value {
                    NavigationLink(value: Route.post(IdentifiedRoute(q))) {
                        QuotedTweetView(tweet: q)
                    }
                    .buttonStyle(.swipeSafe)
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
                onOpenProfile?(t.author)
            } label: {
                Avatar(user: t.author, size: compact ? 28 : Metrics.avatar)
            }
            .buttonStyle(.swipeSafe)
            .accessibilityLabel("Open @\(t.author.screenName) profile")
            // crown-lab: a stable handle for the profile-sheet tests.
            .accessibilityIdentifier("avatar." + t.id)

            VStack(alignment: .leading, spacing: 1) {
                Button {
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
                .buttonStyle(.swipeSafe)
                .accessibilityLabel("Open \(t.author.name)'s profile")

                HStack(spacing: 3) {
                    // The handle gives way first: the time must stay readable on 41 mm.
                    Text("@" + t.author.screenName).lineLimit(1).truncationMode(.tail)
                    if let d = t.createdAt {
                        RelativeTimeText(date: d, prefix: "· ")
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
            MediaThumb(media: m, extraCount: media.count - 1,
                       localURL: SavedStore.shared.localPhoto(tweetID: t.id, index: 0))
                // A tap gesture, not a Button: a Button's press state competes with
                // the scroll view, so a drag that started on an attachment did not
                // scroll, and its action needed a second tap while the list was
                // still settling. A tap is recognised on lift with no press phase.
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { openMedia(media, at: 0) })
                .frame(maxWidth: .infinity)
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Open media")
                // crown-lab: a stable handle for the media-viewer tests.
                .accessibilityIdentifier("media.tile.\(t.id).0")
        }
    }

    /// Opens the viewer on one attachment. A tap that ends a horizontal swipe is
    /// not a tap (the pager and swipe-back use simultaneous gestures).
    private func openMedia(_ media: [XMedia], at index: Int) {
        guard !SwipeGuard.isActive else { return }
        onMedia?(MediaTarget(media: media, startIndex: index,
                             title: t.author.name, caption: t.text))
    }

    private func gridTile(_ media: [XMedia], index: Int, wide: Bool) -> some View {
        let m = media[index]
        let local = SavedStore.shared.localPhoto(tweetID: t.id, index: index)
        return Color.clear
            .aspectRatio(wide ? 2 : 1, contentMode: .fit)
            .overlay {
                RemoteImage(url: local ?? m.feedURL, placeholderURL: m.previewURL,
                            maxPixel: local != nil ? 400 : 300)
            }
            .clipped()
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { openMedia(media, at: index) })
            .frame(maxWidth: .infinity)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(m.altText ?? "Image \(index + 1) of \(media.count)")
            // crown-lab: a stable handle for the media-viewer tests.
            .accessibilityIdentifier("media.tile.\(t.id).\(index)")
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
    private func textBlock(clamped: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            textView(clamped: clamped)
            if clamped {
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
        .buttonStyle(.swipeSafe)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Show more of this post")
    }

    @ViewBuilder
    private func textView(clamped: Bool) -> some View {
        if linkToPost {
            NavigationLink(value: Route.post(IdentifiedRoute(t))) {
                textBody(clamped: clamped)
            }
            .buttonStyle(.swipeSafe)
            // crown-lab: "tap a post" is this link; one id per tweet.
            .accessibilityIdentifier("post.open." + t.id)
        } else {
            textBody(clamped: clamped)
        }
    }

    private func textBody(clamped: Bool) -> some View {
        Text(t.text)
            .font(bodyFont)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .lineLimit(clamped ? 14 : nil)
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
                onOpenProfile?(u)
            } label: {
                UserRow(user: u)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.swipeSafe)
            .padding(.vertical, 6)
        }
    }
}
