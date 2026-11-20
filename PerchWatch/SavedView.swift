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
        // Pushed, not a sheet: swipe right goes back like everywhere else.
        .navigationDestination(item: $selected) { post in
            SavedDetailView(post: post)
        }
    }
}

private struct SavedRow: View {
    let post: SavedStore.SavedPost
    let downloading: Bool

    private var tweet: XTweet { post.tweet.displayed }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                LocalImage(url: SavedStore.shared.fileURL(post.avatarFile), maxPixel: 88)
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(tweet.author.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    Text("@" + tweet.author.screenName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                if downloading {
                    ProgressView().scaleEffect(0.6)
                } else if post.videoFile != nil {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }

            Text(tweet.text)
                .font(.system(size: 15))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let media = tweet.media.first,
               let name = SavedStore.shared.photoFile(post, index: 0) {
                LocalImage(url: SavedStore.shared.fileURL(name), maxPixel: 400)
                    .aspectRatio(max(0.2, media.aspectRatio), contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // Why an attachment is missing, instead of an image that silently never comes.
            if let problem = post.problem, !downloading {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct SavedDetailView: View {
    let post: SavedStore.SavedPost

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

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

                if let player {
                    VideoPlayer(player: player)
                        .frame(height: min(200, WKInterfaceDevice.current().screenBounds.height * 0.45))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
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
        // Item-based destination: `nav.back()` would pop the Saved list underneath, so
        // the swipe is off here (the system edge swipe still pops the detail).
        .swipeBack(enabled: false)
        .onAppear {
            if let name = post.videoFile,
               let url = SavedStore.shared.fileURL(name),
               player == nil {
                let p = AVPlayer(url: url)
                player = p
            }
        }
        .onDisappear {
            // Release the item, not just pause: a paused player keeps the decoder and
            // file open for as long as SwiftUI keeps this state around.
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }
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
