import Foundation
import SwiftUI
import AVKit
import AVFoundation
import Combine
import XKit

/// Full-screen media viewer, presented by the callers with `.fullScreenCover`:
/// black background, one page per media item, swipe sideways, photos zoom with the
/// Digital Crown (drag to pan, single tap toggles 1×/2.5×), videos/GIFs are
/// downloaded first (progress at the bottom) and then autoplay from the local file.
struct MediaViewer: View {
    let media: [XMedia]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    init(media: [XMedia], startIndex: Int) {
        self.media = media
        let start = media.isEmpty ? 0 : min(max(startIndex, 0), media.count - 1)
        _selection = State(initialValue: start)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if media.isEmpty {
                emptyState
            } else {
                pages
                if media.count > 1 { counter }
            }

            closeGesture
        }
        .background(Color.black)
    }

    private var pages: some View {
        TabView(selection: $selection) {
            ForEach(media.indices, id: \.self) { index in
                MediaPage(media: media[index], isActive: selection == index)
                    .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    private var counter: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text("\(selection + 1)/\(media.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
            }
        }
        .accessibilityHidden(true)
    }

    /// `fullScreenCover` already draws the system close (X) button. This invisible
    /// button only claims the hand double-tap so it closes the viewer too.
    private var closeGesture: some View {
        Button {
            dismiss()
        } label: {
            Color.clear
        }
        .buttonStyle(.plain)
        .frame(width: 1, height: 1)
        .opacity(0)
        .accessibilityHidden(true)
        .handGestureShortcut(.primaryAction)
    }

    private var emptyState: some View {
        VStack(spacing: 5) {
            Image(systemName: "photo")
            Text("Nothing to show").font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dispatches one page to the photo or the video/GIF view.
private struct MediaPage: View {
    let media: XMedia
    let isActive: Bool

    var body: some View {
        switch media.type {
        case .photo:
            MediaPhotoPage(media: media)
        case .video, .gif:
            MediaVideoPage(media: media, isActive: isActive)
        }
    }
}

/// One photo page: fit inside the screen, crown zoom, drag to pan, single tap toggles
/// between 1× and 2.5× (centred).
private struct MediaPhotoPage: View {
    let media: XMedia

    @State private var zoom: Double = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            RemoteImage(url: media.fullURL, maxPixel: 1200, contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(panGesture, including: zoom > 1 ? GestureMask.all : GestureMask())
                .onTapGesture { toggleZoom() }
        }
        .focusable()
        .digitalCrownRotation($zoom, from: 1, through: 5, by: 0.1,
                              sensitivity: .medium, isContinuous: false,
                              isHapticFeedbackEnabled: true)
        .onChange(of: zoom) { _, value in
            if value < 1.05 {
                offset = .zero
                dragStart = .zero
            }
        }
        .ignoresSafeArea()
        .accessibilityLabel(media.altText ?? "Image")
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                offset = CGSize(width: dragStart.width + value.translation.width,
                                height: dragStart.height + value.translation.height)
            }
            .onEnded { _ in
                dragStart = offset
                if zoom <= 1 { reset() }
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = zoom > 1.05 ? 1 : 2.5
            offset = .zero
        }
        dragStart = .zero
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            offset = .zero
        }
        dragStart = .zero
    }
}

/// One video/GIF page: downloads the lowest-bitrate MP4 first (thumbnail + thin
/// progress bar + "42% · 180 KB/s" at the bottom), then autoplays the local file
/// while it is the visible page. GIFs loop.
private struct MediaVideoPage: View {
    let media: XMedia
    let isActive: Bool

    @StateObject private var downloader = VideoDownloader()
    @State private var player: AVPlayer?
    @State private var unavailable = false

    var body: some View {
        ZStack {
            Color.black
            if let player {
                VideoPlayer(player: player)
            } else {
                placeholder
            }
        }
        .onAppear { if isActive { start() } }
        .onDisappear { player?.pause() }
        .onChange(of: isActive) { _, active in
            if active { start() } else { player?.pause() }
        }
        .onChange(of: downloader.fileURL) { _, url in
            guard let url, isActive else { return }
            play(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard media.type == .gif,
                  let item = note.object as? AVPlayerItem,
                  item === player?.currentItem else { return }
            player?.seek(to: .zero)
            player?.play()
        }
        .accessibilityLabel(media.altText ?? (media.type == .gif ? "GIF" : "Video"))
    }

    private var placeholder: some View {
        ZStack {
            RemoteImage(url: media.thumbnailURL, maxPixel: 900, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if downloader.error != nil || unavailable {
                Label("Video unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.65), in: Capsule())
            } else {
                VStack(spacing: 4) {
                    Spacer(minLength: 0)
                    progressBar
                    Text(progressText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule()
                    .fill(Color.white)
                    .frame(width: CGFloat(min(1, max(0, downloader.progress))) * geo.size.width)
            }
        }
        .frame(width: 120, height: 3)
    }

    private var progressText: String {
        let rate = downloader.bytesPerSecond > 0
            ? " · " + Self.rateText(downloader.bytesPerSecond)
            : ""
        if downloader.totalBytes == nil, downloader.progress <= 0 {
            return "Downloading" + rate
        }
        let pct = Int((min(1, max(0, downloader.progress)) * 100).rounded())
        return "\(pct)%" + rate
    }

    private func start() {
        if let ready = downloader.fileURL {
            play(ready)
            return
        }
        guard let url = media.lowestBitrateMP4 ?? media.playbackURL(maxBitrate: 0) else {
            unavailable = true
            return
        }
        unavailable = false
        downloader.start(url)
        if let ready = downloader.fileURL { play(ready) }
    }

    private func play(_ url: URL) {
        if let player {
            player.play()
            return
        }
        let p = AVPlayer(url: url)
        player = p
        p.play()
    }

    private static func rateText(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", bps)
    }
}
