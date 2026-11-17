import Foundation
import SwiftUI
import AVKit
import AVFoundation
import Combine
import XKit

/// Full-screen media viewer, presented by the callers with `.fullScreenCover`:
/// black background, swipe sideways between attachments (only when there is more
/// than one), swipe down to close, photos zoom with the Digital Crown (drag to
/// pan, single tap toggles 1×/2.5×) and start from the feed's decoded copy before
/// upgrading to the full-size image, videos/GIFs start playing immediately on the
/// lowest-bitrate MP4 and step up to better variants while they play.
struct MediaViewer: View {
    let media: [XMedia]
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int
    /// The visible photo is zoomed: a downward drag pans instead of closing.
    @State private var zoomed = false
    @State private var dragDown: CGFloat = 0

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
                activePage
                    .offset(y: dragDown)
                if media.count > 1 { counter }
            }

            closeGesture
        }
        .background(Color.black)
        .simultaneousGesture(dismissDrag)
    }

    @ViewBuilder
    private var activePage: some View {
        if media.count == 1 {
            // One attachment is not a pager: no sideways swipe at all.
            MediaPage(media: media[0], isActive: true, zoomed: $zoomed)
                .ignoresSafeArea()
        } else {
            TabView(selection: $selection) {
                ForEach(media.indices, id: \.self) { index in
                    MediaPage(media: media[index],
                              isActive: selection == index,
                              zoomed: selection == index ? $zoomed : .constant(false))
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
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

    /// Swipe down to close (the system X stays too). Ignored while a photo is
    /// zoomed, where the drag pans the image instead.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !zoomed else { return }
                let dy = value.translation.height
                guard dy > 0, abs(dy) > abs(value.translation.width) else { return }
                dragDown = dy
            }
            .onEnded { _ in
                let shouldClose = !zoomed && dragDown > 60
                withAnimation(.easeOut(duration: 0.2)) { dragDown = 0 }
                if shouldClose { dismiss() }
            }
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
    @Binding var zoomed: Bool

    var body: some View {
        switch media.type {
        case .photo:
            MediaPhotoPage(media: media, zoomed: $zoomed)
        case .video, .gif:
            MediaVideoPage(media: media, isActive: isActive)
        }
    }
}

/// One photo page: fit inside the screen, crown zoom, drag to pan (clamped to the
/// image so zooming out can never leave black around a corner), single tap
/// toggles between 1× and 2.5× (centred).
private struct MediaPhotoPage: View {
    let media: XMedia
    @Binding var zoomed: Bool

    @State private var zoom: Double = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero
    @State private var container: CGSize = .zero
    /// Start with what the feed already decoded; upgrade to the full image when
    /// the link can afford it (or as soon as the reader zooms in).
    @State private var wantsFull = false

    /// What the feed already shows (and has decoded): on screen in the first
    /// frame, while the full-size image is fetched behind it.
    private var feed: (url: URL, maxPixel: Int) { ImageLoader.feedImage(for: media) }

    private var target: (url: URL, maxPixel: Int) {
        wantsFull ? (media.fullURL, 1200) : feed
    }

    var body: some View {
        GeometryReader { geo in
            RemoteImage(url: target.url, maxPixel: target.maxPixel, contentMode: .fit,
                        fallbackURL: feed.url, fallbackMaxPixel: feed.maxPixel)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoom)
                .offset(clamped(offset, in: geo.size))
                .gesture(panGesture(in: geo.size), including: zoom > 1 ? GestureMask.all : GestureMask())
                .onTapGesture { toggleZoom() }
                .onAppear { container = geo.size }
                .onChange(of: geo.size) { _, size in container = size }
        }
        .focusable()
        .digitalCrownRotation($zoom, from: 1, through: 5, by: 0.1,
                              sensitivity: .medium, isContinuous: false,
                              isHapticFeedbackEnabled: true)
        .onChange(of: zoom) { _, value in
            zoomed = value > 1.05
            // Zooming in is the moment the extra resolution matters.
            if value > 1.05, !wantsFull { wantsFull = true }
            if value < 1.05 {
                offset = .zero
                dragStart = .zero
            } else {
                // Shrinking the zoom shrinks how far the image may travel: keep
                // the panned image inside its frame instead of letting it sit
                // off-centre with black around it.
                offset = clamped(offset, in: container)
                dragStart = offset
            }
        }
        .onAppear {
            zoomed = zoom > 1.05
            wantsFull = LinkSpeed.prefersFullPhoto(media)
        }
        .onDisappear { zoomed = false }
        .ignoresSafeArea()
        .accessibilityLabel(media.altText ?? "Image")
    }

    /// Largest offset that still keeps the scaled image covering the frame in
    /// each axis (0 when the image is smaller than the screen in that axis).
    private func clamped(_ o: CGSize, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let ratio = CGFloat(media.aspectRatio > 0 ? media.aspectRatio : 1)
        let fittedWidth = min(size.width, size.height * ratio)
        let fittedHeight = fittedWidth / ratio
        let scale = CGFloat(zoom)
        let maxX = max(0, (fittedWidth * scale - size.width) / 2)
        let maxY = max(0, (fittedHeight * scale - size.height) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)),
                      height: min(maxY, max(-maxY, o.height)))
    }

    private func panGesture(in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }
                let next = CGSize(width: dragStart.width + value.translation.width,
                                  height: dragStart.height + value.translation.height)
                offset = clamped(next, in: size)
            }
            .onEnded { _ in
                dragStart = offset
            }
    }

    private func toggleZoom() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = zoom > 1.05 ? 1 : 2.5
            offset = .zero
        }
        dragStart = .zero
    }
}

/// One video/GIF page. Playback starts immediately on the lowest-bitrate MP4 and
/// `VideoPlayback` steps up to better variants while it plays (see that file).
/// Until the first frame is up, the thumbnail and a thin buffer bar are shown.
private struct MediaVideoPage: View {
    let media: XMedia
    let isActive: Bool

    @StateObject private var playback = VideoPlayback()
    @State private var muted = false

    var body: some View {
        ZStack {
            Color.black
            VideoPlayer(player: playback.player)
                .ignoresSafeArea()

            if let failure = playback.failed {
                unavailable(failure)
            } else if playback.loading {
                loadingOverlay
            }

            controls
        }
        .onAppear { if isActive { playback.start(media) } }
        .onDisappear { playback.teardown() }
        .onChange(of: isActive) { _, active in
            if active { playback.start(media) } else { playback.stop() }
        }
        .onChange(of: muted) { _, value in
            playback.setMuted(value)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem,
                  item === playback.player.currentItem else { return }
            if media.type == .gif {
                playback.replay()
            } else {
                playback.markEnded()
            }
        }
        .accessibilityLabel(media.altText ?? (media.type == .gif ? "GIF" : "Video"))
    }

    private func unavailable(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65), in: Capsule())
    }

    /// Thumbnail + how much of the video is buffered, until it starts playing.
    private var loadingOverlay: some View {
        ZStack {
            RemoteImage(url: media.thumbnailURL, maxPixel: 900, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 5) {
                Spacer(minLength: 0)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * CGFloat(min(1, max(0.03, playback.buffered))))
                    }
                }
                .frame(width: 120, height: 3)
                Text(bufferingText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var bufferingText: String {
        guard playback.buffered > 0.02 else { return "Buffering" }
        return "Buffering \(Int((playback.buffered * 100).rounded()))%"
    }

    /// Mute toggle (top-right, opposite the system close button) and a replay
    /// button once a video has ended. GIFs just loop.
    private var controls: some View {
        ZStack {
            if playback.endedFlag, media.type != .gif {
                Button {
                    playback.replay()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(13)
                        .background(Color.black.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replay")
            }

            VStack {
                HStack(spacing: 4) {
                    if !playback.quality.isEmpty {
                        Text(playback.quality)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.5), in: Capsule())
                    }
                    Spacer(minLength: 2)
                    Button {
                        muted.toggle()
                    } label: {
                        Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(muted ? "Unmute" : "Mute")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 4)
            .padding(.horizontal, 6)
        }
    }
}

/// Very rough link-speed gate for big images: the feed copy is already sharp on
/// the watch screen, so the 1200 px version is only fetched when it will not
/// crawl down a slow (Bluetooth-relayed) connection.
enum LinkSpeed {
    static func prefersFullPhoto(_ media: XMedia) -> Bool {
        if ImageLoader.shared.cached(media.fullURL, maxPixel: 1200) != nil { return true }
        let pixels = media.width * media.height
        guard pixels > 0 else { return true }
        // ~0.2 bytes per pixel is typical for the JPEGs X serves.
        let estimate = Double(pixels) * 0.2
        let rate = TransferMonitor.shared.snapshot().bytesPerSecond
        guard rate > 1 else { return true }          // idle: no measurement to trust
        return estimate / rate <= 3
    }
}
