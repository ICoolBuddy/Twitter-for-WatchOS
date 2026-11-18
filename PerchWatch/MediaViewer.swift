import Foundation
import SwiftUI
import WatchKit
import AVKit
import AVFoundation
import Combine
import XKit

/// Full-screen media viewer, presented by `MediaPresenter` (a `fullScreenCover` at
/// the root, an overlay `MediaHost` inside the profile sheet): black background,
/// swipe sideways between attachments (only when there is more than one), swipe
/// down to close, photos zoom with the Digital Crown and start from the feed's
/// decoded copy, videos play one MP4 chosen from the measured link speed.
///
/// No chrome of our own (owner, 2026-11-18): no close button and no video
/// controls. Videos and GIFs use the system player's controls; the viewer
/// closes with a swipe down or a hand double-tap. Inside the root
/// `fullScreenCover` watchOS' own X is hidden too (`inCover`).
struct MediaViewer: View {
    let media: [XMedia]
    /// Now Playing text for videos (author, post text).
    var title: String? = nil
    var caption: String? = nil
    /// Dismiss handler (`nil` = the environment's `dismiss`).
    var onClose: (() -> Void)? = nil
    /// Presented as a `fullScreenCover`: hide the X and the clock watchOS draws on it.
    var inCover = false

    @Environment(\.dismiss) private var dismiss
    /// The viewer is going away: pages drop crown focus and close actions are
    /// ignored. Local, so the root host, a sheet's host and a cover behave the
    /// same. Never cleared: this instance is on its way out.
    @State private var closing = false
    @State private var selection: Int
    /// The visible photo is zoomed: a downward drag pans instead of closing.
    @State private var zoomed = false
    @State private var dragDown: CGFloat = 0
    /// Warms the full-size photo a swipe would land on.
    @State private var neighbourPrefetch: Task<Void, Never>?

    init(media: [XMedia], startIndex: Int, title: String? = nil, caption: String? = nil,
         onClose: (() -> Void)? = nil, inCover: Bool = false) {
        self.media = media
        self.title = title
        self.caption = caption
        self.onClose = onClose
        self.inCover = inCover
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
            #if DEBUG
            // Crown routing tests: "the viewer is open", whichever close button it has.
            Text(verbatim: "viewer")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityIdentifier("media.viewer")
            #endif
        }
        .background(Color.black)
        .simultaneousGesture(dismissDrag)
        .modifier(CoverChrome(hidden: inCover))
        .onChange(of: selection, initial: true) { _, index in
            // `zoomed` decides whether a downward drag pans or closes, and only the
            // visible page can write it: paging away from a zoomed photo used to leave
            // it true, which killed swipe-down-to-close on the next page.
            zoomed = false
            dragDown = 0
            prefetchNeighbours(around: index)
        }
        .onDisappear { neighbourPrefetch?.cancel() }
    }

    @ViewBuilder
    private var activePage: some View {
        if media.count == 1 {
            // One attachment is not a pager: no sideways swipe at all.
            MediaPage(media: media[0], title: title, caption: caption, isActive: true,
                      closing: closing,
                      zoomed: $zoomed)
                .ignoresSafeArea()
        } else {
            TabView(selection: $selection) {
                ForEach(media.indices, id: \.self) { index in
                    MediaPage(media: media[index], title: title, caption: caption,
                              isActive: selection == index,
                              closing: closing,
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

    // MARK: Closing

    private func close() {
        guard !closing else { return }
        // Same update: the pages stop being focusable candidates on the way out,
        // so the crown is free while the viewer fades.
        closing = true
        if let onClose { onClose() } else { dismiss() }
    }

    /// Swipe down to close (ignored while a photo is zoomed: that drag pans).
    /// The photo a swipe would land on, decoded ahead (the same URL + size the page asks
    /// for), so it does not go soft→sharp on arrival. Bounded by the prefetch gate,
    /// cancelled on every swipe, and skipped on a slow or unmeasured link.
    private func prefetchNeighbours(around index: Int) {
        neighbourPrefetch?.cancel()
        guard media.count > 1 else { return }
        let urls = [index - 1, index + 1]
            .filter { media.indices.contains($0) && media[$0].type == .photo }
            .filter { LinkSpeed.prefersFullPhoto(media[$0]) }
            .map { media[$0].fullURL }
        guard !urls.isEmpty else { return }
        neighbourPrefetch = ImageLoader.shared.prefetch(urls, maxPixel: 1200)
    }

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
                if shouldClose { close() }
            }
    }

    /// Hand double-tap closes the viewer too.
    private var closeGesture: some View {
        Button {
            close()
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
    var title: String?
    var caption: String?
    let isActive: Bool
    /// The viewer is closing: no page may hold the crown any more.
    let closing: Bool
    @Binding var zoomed: Bool

    var body: some View {
        switch media.type {
        case .photo:
            MediaPhotoPage(media: media, isActive: isActive, closing: closing,
                           zoomed: $zoomed)
        case .video, .gif:
            MediaVideoPage(media: media, title: title, caption: caption, isActive: isActive,
                           closing: closing)
        }
    }
}

/// One photo page: fit inside the screen, crown zoom, drag to pan (clamped to the
/// image so zooming out can never leave black around a corner), single tap
/// toggles between 1× and 2.5× (centred).
private struct MediaPhotoPage: View {
    let media: XMedia
    let isActive: Bool
    let closing: Bool
    @Binding var zoomed: Bool

    /// The crown zooms the photo on screen (with several attachments, focus
    /// used to stay on the first page).
    @FocusState private var crownFocused: Bool

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
        // Only the page on screen may take the crown, and never once the viewer
        // has started closing: an off-screen page must not swallow it, and the
        // crown has to be free again while the viewer fades out.
        .focusable(isActive && !closing)
        .focused($crownFocused)
        .onChange(of: isActive) { _, active in
            if active {
                // While off screen this page could not write `zoomed`: re-publish its zoom.
                zoomed = zoom > 1.05
                // The full-size copy is for the page on screen.
                if !wantsFull { wantsFull = LinkSpeed.prefersFullPhoto(media) }
                claimCrown()
            } else {
                crownFocused = false
            }
        }
        .onChange(of: closing) { _, closing in
            if closing { crownFocused = false }
        }
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
            // Only the page on screen earns the 1200 px copy (4–6 MB decoded, held for
            // the life of the viewer): a paged TabView appears its neighbours too.
            if isActive {
                zoomed = zoom > 1.05
                wantsFull = LinkSpeed.prefersFullPhoto(media)
                claimCrown()
            }
        }
        .onDisappear { zoomed = false }
        .ignoresSafeArea()
        .accessibilityLabel(media.altText ?? "Image")
    }

    /// After the viewer's open animation; focusing during it does not stick.
    private func claimCrown() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if isActive, !closing { crownFocused = true }
        }
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

/// One video/GIF page: the system player with its own controls (play/pause,
/// progress, Done) and its own Digital Crown volume, as in Apple's apps. We only
/// pick and load the file (`VideoPlayback`: lowest-bitrate MP4 first, retry,
/// background audio) and show the poster + buffering bar until the first frame.
///
/// There used to be our own play button, timestamps, scrubbing and a volume HUD
/// over a `.disabled` player; the system player still drew its controls (at the
/// end of a video, or on a tap), so two sets overlapped (device, 2026-11-18).
private struct MediaVideoPage: View {
    let media: XMedia
    var title: String?
    var caption: String?
    let isActive: Bool
    /// The viewer is closing: the player lets go of the crown on the way out.
    let closing: Bool

    @StateObject private var playback = VideoPlayback()

    var body: some View {
        ZStack {
            Color.black
            VideoPlayer(player: playback.player)
                // Only the page on screen may take the crown (several attachments),
                // and none once the viewer is closing.
                .disabled(!isActive || closing)
                .ignoresSafeArea()

            // Poster until the first frame is really on screen (no black flash),
            // and behind an error. Never hit-testable: taps reach the player.
            if playback.loading || playback.failed != nil {
                poster
            }
            if let failure = playback.failed {
                unavailable(failure)
            } else if playback.loading {
                loadingBar
            }
        }
        .onAppear {
            if isActive { playback.start(media, title: title, caption: caption) }
        }
        .onDisappear { playback.teardown() }
        .onChange(of: isActive) { _, active in
            if active {
                playback.start(media, title: title, caption: caption)
            } else {
                playback.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem,
                  item === playback.player.currentItem else { return }
            // GIFs loop: the player does not pause at the end (`actionAtItemEnd`
            // = .none), so the system controls never pop up between loops.
            if media.type == .gif { playback.replay() } else { playback.markEnded() }
        }
        .accessibilityLabel(media.altText ?? (media.type == .gif ? "GIF" : "Video"))
    }

    private var poster: some View {
        let feed = ImageLoader.feedImage(for: media)
        return RemoteImage(url: media.thumbnailURL, maxPixel: 900, contentMode: .fit,
                           fallbackURL: feed.url, fallbackMaxPixel: feed.maxPixel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    private func unavailable(_ message: String) -> some View {
        Button {
            playback.retry()
        } label: {
            VStack(spacing: 3) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                Text("Tap to retry")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.65), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(message). Tap to retry.")
    }

    /// How much of the video is buffered, until it starts playing.
    private var loadingBar: some View {
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
        .allowsHitTesting(false)
    }

    private var bufferingText: String {
        guard playback.buffered > 0.02 else { return "Buffering" }
        return "Buffering \(Int((playback.buffered * 100).rounded()))%"
    }
}

/// Inside the root `fullScreenCover`: no watchOS X button and no clock over the
/// media (owner, 2026-11-18). The cover itself stays: dismissing a real
/// presentation is what hands the Digital Crown back to the feed (AGENTS.md §8.4).
private struct CoverChrome: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if hidden {
            content
                .toolbar(.hidden, for: .navigationBar)
                ._statusBarHidden(true)
        } else {
            content
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
        // Within ~3 s on the measured link; with no measurement yet, the feed copy
        // (it was "fetch the 1200 px one" before, i.e. unknown counted as fast).
        return !LinkBudget.isTooSlow(bytes: Double(pixels) * LinkBudget.bytesPerPixel, seconds: 3)
    }
}
