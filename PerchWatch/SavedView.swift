import SwiftUI
import AVKit
import AVFoundation
import WatchKit
import XKit

/// Offline posts, saved from the post page. Everything here renders from local
/// files, so it works with no connection at all.
struct SavedView: View {
    @ObservedObject private var store = SavedStore.shared
    @State private var selected: SavedStore.SavedPost?
    @State private var used: Int64 = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if store.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("No saved posts")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Open a post and tap the download button to keep it offline.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }

                if !store.items.isEmpty {
                    Text("Used \(ByteCountFormatter.string(fromByteCount: used, countStyle: .file)) of 250 MB")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }

                ForEach(store.items) { post in
                    Button {
                        selected = post
                    } label: {
                        SavedRow(post: post, downloading: store.saving.contains(post.id))
                    }
                    .buttonStyle(.swipeSafe)
                    PostSeparator()
                }
            }
            .padding(.horizontal, Metrics.horizontalPadding)
        }
        .background(Color.black)
        .navigationTitle("Saved")
        .task(id: store.items.count) { used = store.usedBytes() }
        // crown-lab measurement hook (DEBUG only): `probe.saved`.
        .crownProbe("saved")
        .swipeBack()
        // Pushed, not a sheet: swipe right goes back like everywhere else. The
        // destination is item-based, so the pop clears the item instead of `nav.back()`
        // (which would pop the Saved list underneath).
        .navigationDestination(item: $selected) { post in
            SavedDetailView(post: post, onPop: { selected = nil })
        }
    }
}

private struct SavedRow: View {
    let post: SavedStore.SavedPost
    let downloading: Bool

    @AppStorage(PerchSettings.textSize) private var textSizeRaw = PerchTextSize.medium.rawValue

    private var tweet: XTweet { post.tweet.displayed }

    /// Same scale as the feed, so a saved post reads like the post it was saved from.
    private var textScale: CGFloat {
        (PerchTextSize(rawValue: textSizeRaw) ?? .medium).scale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The feed's header (avatar, name, handle, time), not a compact variant:
            // the Saved list is a reading list and should look like the feed.
            TweetHeader(tweet: tweet)

            Text(tweet.text)
                .font(.system(size: 19 * textScale))
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The saved copy of the media: a photo's file, or the video's poster frame
            // (saved with it), so the tile is there offline too. A video keeps the
            // feed's play glyph.
            if let media = tweet.media.first {
                MediaThumb(media: media,
                           extraCount: tweet.media.count - 1,
                           localURL: SavedStore.shared.localPhoto(tweetID: tweet.id, index: 0))
            }

            if downloading {
                ProgressView().scaleEffect(0.6)
            } else if let problem = post.problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SavedDetailView: View {
    let post: SavedStore.SavedPost
    /// Pops this item-based destination (clearing `selected` in `SavedView`).
    let onPop: () -> Void

    @Environment(\.dismiss) private var dismiss
    /// The saved file, opened full screen (the inline player was a 200 pt box with the
    /// video's own controls, and its gesture swallowed the swipe-back).
    @State private var fullScreenVideo: SavedVideoFile?

    private var tweet: XTweet { post.tweet.displayed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    LocalImage(url: SavedStore.shared.fileURL(post.avatarFile), maxPixel: 88)
                        .frame(width: 30, height: 30)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 0) {
                        Text(tweet.author.name)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                        Text("@" + tweet.author.screenName)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text(tweet.text)
                    .font(.system(size: 17))
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(tweet.media.enumerated()), id: \.offset) { index, media in
                    if let name = SavedStore.shared.photoFile(post, index: index) {
                        LocalImage(url: SavedStore.shared.fileURL(name), maxPixel: 900)
                            .aspectRatio(max(0.2, media.aspectRatio), contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                if let name = post.videoFile, let url = SavedStore.shared.fileURL(name) {
                    Button { fullScreenVideo = SavedVideoFile(url: url) } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.08))
                            VStack(spacing: 4) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 34))
                                Text("Play video")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Full screen, with sound")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(height: min(120, WKInterfaceDevice.current().screenBounds.height * 0.3))
                    }
                    .buttonStyle(.swipeSafe)
                    .accessibilityLabel("Play saved video with sound")
                }

                if let live = SavedStore.shared.items.first(where: { $0.id == post.id }),
                   let problem = live.problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Button(role: .none) { SavedStore.shared.retry(post.id) } label: {
                        Label("Retry download", systemImage: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.swipeSafe)
                }

                Button(role: .destructive, action: SwipeGuard.run {
                    SavedStore.shared.remove(post.id)
                    dismiss()
                }) {
                    Text("Remove from saved")
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, 6)
        }
        .background(Color.black)
        .navigationTitle("Saved post")
        // Swipe right pops this detail by clearing the item. It used to be disabled
        // because `nav.back()` would pop the list underneath; the explicit `onPop`
        // makes the pop safe, and there is no inline player left to eat the drag.
        .swipeBack(onPop: onPop)
        .fullScreenCover(item: $fullScreenVideo) { file in
            // The same viewer the timeline uses: watchOS' cover chrome hidden, the
            // crown drives the system volume, the system player draws its controls.
            // A local file needs no variants; `VideoPlayback` plays it directly.
            MediaViewer(media: [XMedia(id: "saved-\(file.url.lastPathComponent)",
                                       type: .video, url: file.url,
                                       width: 1920, height: 1080)],
                        startIndex: 0,
                        title: tweet.author.name,
                        caption: tweet.text,
                        inCover: true)
        }
    }
}

/// `fullScreenCover(item:)` needs an `Identifiable`: a file URL is not one.
private struct SavedVideoFile: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// An image from a local file (saved posts). Falls back to a quiet block when the
/// file is not there yet.
struct LocalImage: View {
    let url: URL?
    var maxPixel: Int = 400

    var body: some View {
        if url != nil {
            RemoteImage(url: url, maxPixel: maxPixel, contentMode: .fit)
        } else {
            Rectangle().fill(Color.white.opacity(0.06))
        }
    }
}
