import Foundation
import SwiftUI
import WatchKit
import AVKit
import AVFoundation
import Combine
import XKit

/// Full-screen media viewer, drawn as an overlay at the root (see
/// `MediaPresenter`): black background, swipe sideways between attachments (only
/// when there is more than one), swipe down to close, photos zoom with the
/// Digital Crown and start from the feed's decoded copy, videos start playing
/// immediately on a small MP4 and step up to better variants while they play.
///
/// The chrome (close button) hides itself after a second; tapping brings it back.
struct MediaViewer: View {
    let media: [XMedia]
    /// Now Playing text for videos (author, post text).
    var title: String? = nil
    var caption: String? = nil
    /// Dismiss handler for the root overlay presentation (`nil` inside a cover).
    var onClose: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int
    /// The visible photo is zoomed: a downward drag pans instead of closing.
    @State private var zoomed = false
    @State private var dragDown: CGFloat = 0
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    init(media: [XMedia], startIndex: Int, title: String? = nil, caption: String? = nil,
         onClose: (() -> Void)? = nil) {
        self.media = media
        self.title = title
        self.caption = caption
        self.onClose = onClose
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

            closeButton
            closeGesture
        }
        .background(Color.black)
        .simultaneousGesture(dismissDrag)
        .onAppear { showControls() }
        .onDisappear { hideTask?.cancel() }
    }

    @ViewBuilder
    private var activePage: some View {
        if media.count == 1 {
            // One attachment is not a pager: no sideways swipe at all.
            MediaPage(media: media[0], title: title, caption: caption, isActive: true, zoomed: $zoomed,
                      controlsVisible: $controlsVisible,
                      touch: showControls, toggleControls: toggleControls)
                .ignoresSafeArea()
        } else {
            TabView(selection: $selection) {
                ForEach(media.indices, id: \.self) { index in
                    MediaPage(media: media[index], title: title, caption: caption,
                              isActive: selection == index,
                              zoomed: selection == index ? $zoomed : .constant(false),
                              controlsVisible: $controlsVisible,
                              touch: showControls,
                              toggleControls: toggleControls)
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

    // MARK: Chrome

    /// Our own close button (the overlay has no system one). Visible for a
    /// moment, then it fades so the picture/video fills the screen.
    private var closeButton: some View {
        VStack {
            HStack {
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.top, 2)
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeOut(duration: 0.2), value: controlsVisible)
    }

    private func showControls() {
        hideTask?.cancel()
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
        }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
        }
    }

    private func hideControls() {
        hideTask?.cancel()
        hideTask = nil
        withAnimation(.easeOut(duration: 0.25)) { controlsVisible = false }
    }

    private func toggleControls() {
        if controlsVisible { hideControls() } else { showControls() }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    /// Swipe down to close (ignored while a photo is zoomed: that drag pans).
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
    @Binding var zoomed: Bool
    @Binding var controlsVisible: Bool
    let touch: () -> Void
    let toggleControls: () -> Void

    var body: some View {
        switch media.type {
        case .photo:
            MediaPhotoPage(media: media, isActive: isActive, zoomed: $zoomed, touch: touch)
        case .video, .gif:
            MediaVideoPage(media: media, title: title, caption: caption, isActive: isActive,
                           controlsVisible: $controlsVisible,
                           touch: touch, toggleControls: toggleControls)
        }
    }
}

/// One photo page: fit inside the screen, crown zoom, drag to pan (clamped to the
/// image so zooming out can never leave black around a corner), single tap
/// toggles between 1× and 2.5× (centred) and brings the close button back.
private struct MediaPhotoPage: View {
    let media: XMedia
    let isActive: Bool
    @Binding var zoomed: Bool
    let touch: () -> Void

    /// The crown zooms the photo on screen (with several attachments, focus
    /// used to stay on the first page).
    @FocusState private var crownFocused: Bool
    @ObservedObject private var presenter = MediaPresenter.shared

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
                .onTapGesture {
                    touch()
                    toggleZoom()
                }
                .onAppear { container = geo.size }
                .onChange(of: geo.size) { _, size in container = size }
        }
        .focusable()
        .focused($crownFocused)
        .onChange(of: isActive) { _, active in
            if active { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { crownFocused = true } }
        }
        .onChange(of: presenter.closing) { _, closing in
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
            zoomed = zoom > 1.05
            wantsFull = LinkSpeed.prefersFullPhoto(media)
            if isActive { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { crownFocused = true } }
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

/// One video/GIF page.
///
/// The Digital Crown changes the *Watch's* volume while the video is clean
/// (through WatchKit's system volume control, so it starts at the current
/// volume and is the same setting Now Playing uses); after a tap
/// (which shows the play/pause button and the timestamp) it scrubs. Both give a
/// haptic detent (every 5 % of volume, every second of video). The page holds
/// crown focus itself; AVKit's player is display-only, so it can never take the
/// crown or the taps away.
private struct MediaVideoPage: View {
    let media: XMedia
    var title: String?
    var caption: String?
    let isActive: Bool
    @Binding var controlsVisible: Bool
    let touch: () -> Void
    let toggleControls: () -> Void

    @StateObject private var playback = VideoPlayback()
    @FocusState private var crownFocused: Bool
    @ObservedObject private var presenter = MediaPresenter.shared
    @State private var crown = 0.0
    @State private var lastCrown = 0.0
    @State private var volumeHUD: Double?
    @State private var volumeTask: Task<Void, Never>?
    /// Last detent that played a haptic (volume step or whole second).
    @State private var lastDetent: Int?
    @State private var lastHaptic = Date.distantPast

    var body: some View {
        ZStack {
            Color.black
            VideoPlayer(player: playback.player)
                .disabled(true)              // no AVKit controls, focus or crown
                .allowsHitTesting(false)
                .ignoresSafeArea()

            // Poster until the first frame is really on screen (no black flash),
            // and behind an error.
            if playback.loading || playback.failed != nil {
                poster
            }
            if let failure = playback.failed {
                unavailable(failure)
            } else if playback.loading {
                loadingBar
            } else if playback.stalled {
                ProgressView()
                    .allowsHitTesting(false)
            }

            // Swallow taps: AVKit's own controls never appear, the chrome is ours.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleControls()
                    claimCrown()
                }

            if controlsVisible { controls }
            if let volume = volumeHUD { volumeOverlay(volume) }

            // The system volume control owns the crown while the chrome is
            // hidden. Nearly invisible: our HUD above shows the level.
            SystemVolumeControl(focused: isActive && !controlsVisible && !presenter.closing)
                .frame(width: 40, height: 40)
                .opacity(0.02)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation($crown, from: -100_000, through: 100_000, by: 1,
                              sensitivity: .low, isContinuous: false,
                              isHapticFeedbackEnabled: false)
        .onChange(of: crown) { _, value in
            let delta = value - lastCrown
            lastCrown = value
            guard abs(delta) > 0.01 else { return }
            // Only reached while our page holds the crown (chrome visible).
            guard controlsVisible else { return }
            let target = playback.scrub(bySeconds: delta * 0.5)
            detent(Int(target.rounded(.down)))
            touch()
        }
        .onChange(of: controlsVisible) { _, visible in
            lastDetent = nil
            // Chrome visible: our page takes the crown (scrub). Hidden: hand it
            // to the system volume control.
            crownFocused = visible && isActive
        }
        // The Watch's volume changed (crown, or the Now Playing app): show it.
        .onChange(of: playback.systemVolume) { _, value in
            if isActive, !controlsVisible { showVolume(value) }
        }
        .onChange(of: presenter.closing) { _, closing in
            if closing { crownFocused = false }
        }
        .onAppear {
            if isActive {
                playback.start(media, title: title, caption: caption)
                claimCrown()
            }
        }
        .onDisappear {
            playback.teardown()
            volumeTask?.cancel()
        }
        .onChange(of: isActive) { _, active in
            if active {
                playback.start(media, title: title, caption: caption)
                claimCrown()
            } else {
                playback.stop()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { note in
            guard let item = note.object as? AVPlayerItem,
                  item === playback.player.currentItem else { return }
            if media.type == .gif {
                playback.replay()
            } else {
                playback.markEnded()
                touch()
            }
        }
        .accessibilityLabel(media.altText ?? (media.type == .gif ? "GIF" : "Video"))
    }

    private func claimCrown() {
        // After the viewer's open animation; focusing during it does not stick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            // Scrubbing needs our focus; volume belongs to the system control.
            if isActive { crownFocused = controlsVisible }
        }
    }

    /// A click each time the crown crosses a detent (rate-limited so a fast
    /// spin does not buzz continuously).
    private func detent(_ value: Int) {
        defer { lastDetent = value }
        guard let last = lastDetent, last != value else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHaptic) > 0.06 else { return }
        lastHaptic = now
        WKInterfaceDevice.current().play(.click)
    }

    private var poster: some View {
        let feed = ImageLoader.feedImage(for: media)
        return RemoteImage(url: media.thumbnailURL, maxPixel: 900, contentMode: .fit,
                           fallbackURL: feed.url, fallbackMaxPixel: feed.maxPixel)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    private func unavailable(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.65), in: Capsule())
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

    /// Play/pause in the middle and the timestamp + position bar at the bottom.
    private var controls: some View {
        ZStack {
            Button {
                playback.togglePlayPause()
                touch()
                claimCrown()
            } label: {
                Image(systemName: controlIcon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.endedFlag ? "Replay" : (playback.isPlaying ? "Pause" : "Play"))

            VStack {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(Self.clock(playback.position))
                    Spacer(minLength: 0)
                    Text(Self.clock(playback.duration))
                }
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * progressFraction)
                    }
                }
                .frame(height: 2.5)
                .padding(.top, 3)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .allowsHitTesting(false)
        }
    }

    private var controlIcon: String {
        if playback.endedFlag { return "arrow.counterclockwise" }
        return playback.isPlaying ? "pause.fill" : "play.fill"
    }

    private var progressFraction: CGFloat {
        guard playback.duration > 0 else { return 0 }
        return CGFloat(min(1, max(0, playback.position / playback.duration)))
    }

    /// Small transient speaker bar while the crown changes the volume.
    private func volumeOverlay(_ value: Double) -> some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Image(systemName: value <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10, weight: .semibold))
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.25))
                        Capsule()
                            .fill(Color.white)
                            .frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
                    }
                }
                .frame(width: 70, height: 3)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.6), in: Capsule())
            .padding(.bottom, 34)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func showVolume(_ value: Float) {
        volumeTask?.cancel()
        volumeHUD = Double(value)
        volumeTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { volumeHUD = nil }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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

/// WatchKit's system volume control, which SwiftUI has no equivalent of. When
/// focused it takes the Digital Crown and changes the Watch's own output volume
/// (with the system's haptics), starting from the current level.
struct SystemVolumeControl: WKInterfaceObjectRepresentable {
    var focused: Bool

    func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
        let control = WKInterfaceVolumeControl(origin: .local)
        control.setTintColor(.white)
        return control
    }

    func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
        if focused { control.focus() } else { control.resignFocus() }
    }
}
