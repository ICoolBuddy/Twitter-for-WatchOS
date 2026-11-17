import SwiftUI
import AVKit
import AVFoundation
import Combine
import XKit

/// Full-screen media viewer, presented by the callers with `.fullScreenCover`:
/// black background, one page per media item, swipe sideways, photos zoom with the
/// Digital Crown (drag to pan, double-tap to reset), videos/GIFs autoplay.
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
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if media.isEmpty {
                emptyState
            } else {
                pages
                if media.count > 1 { counter }
            }

            closeButton
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

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 4)
        .padding(.top, 2)
        .accessibilityLabel("Close")
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

/// One photo page: Fit inside the screen, crown zoom, drag to pan, double-tap to reset.
private struct MediaPhotoPage: View {
    let media: XMedia

    @State private var zoom: Double = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            RemoteImage(url: media.imageURL(size: "medium"), maxPixel: 1200, contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoom)
                .offset(offset)
                .gesture(panGesture, including: zoom > 1 ? GestureMask.all : GestureMask())
                .onTapGesture(count: 2) { reset() }
        }
        .focusable()
        .digitalCrownRotation($zoom, from: 1, through: 5, by: 0.1,
                              sensitivity: .medium, isContinuous: false,
                              isHapticFeedbackEnabled: true)
        .onChange(of: zoom) { _, value in
            if value < 1.05 { reset() }
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

    private func reset() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            offset = .zero
        }
        dragStart = .zero
    }
}

/// One video/GIF page: autoplays while it is the visible page, pauses otherwise.
/// GIFs loop because they have no useful end state.
private struct MediaVideoPage: View {
    let media: XMedia
    let isActive: Bool

    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.black
            RemoteImage(url: media.thumbnailURL, maxPixel: 900, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let player {
                VideoPlayer(player: player)
            } else if failed {
                Label("Video unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.65), in: Capsule())
            }
        }
        .onAppear { if isActive { start() } }
        .onDisappear { player?.pause() }
        .onChange(of: isActive) { _, active in
            if active { start() } else { player?.pause() }
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

    private func start() {
        if let player {
            player.play()
            return
        }
        guard let url = media.playbackURL() else {
            failed = true
            return
        }
        let p = AVPlayer(url: url)
        player = p
        p.play()
    }
}
