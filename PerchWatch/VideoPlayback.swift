import Foundation
import AVFoundation
import MediaPlayer
import Combine
import XKit

/// Playback for a post's video on the Watch.
///
/// The quality is chosen once, before playing, from the measured link speed
/// (and remembered per post). It used to step up mid-play by swapping the
/// player item, which rebuffered and showed black frames each time; a single
/// item for the whole playback is what makes the player behave.
@MainActor
final class VideoPlayback: ObservableObject {
    let player = AVPlayer()

    /// 0…1 of the video that is downloaded/buffered (drives the loading bar).
    @Published private(set) var buffered: Double = 0
    /// True until the first frame has really been shown (poster + bar on top).
    @Published private(set) var loading = true
    @Published private(set) var failed: String?
    // Not published: the page draws none of these (the system player has its own
    // controls); they feed Now Playing and the remote commands only.
    private(set) var endedFlag = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false

    private var levels: [XVideoVariant] = []
    private var mediaId: String?
    private var ticker: Task<Void, Never>?
    /// Where an in-flight crown scrub is going. While set, the ticker does not
    /// overwrite `position` with the player's (older) time, so consecutive crown
    /// turns add up instead of snapping back.
    private var scrubTarget: Double?
    private var seekToken = 0
    /// A video request that failed on the network is retried once by itself, and
    /// then only by tapping the message: the Watch reaches the CDN through the
    /// iPhone, and the first request does time out now and then (NSURLError
    /// -1001) without anything being wrong with the post.
    private var retriedNetworkFailure = false
    private var retryTask: Task<Void, Never>?

    /// Now Playing text and the remote-command handlers registered for it.
    private var title: String?
    private var caption: String?
    private var commandTokens: [(MPRemoteCommand, Any)] = []
    private var lastNowPlaying = Date.distantPast
    private var backgroundSession = false

    /// Quality level used per post, for this app run.
    private static var chosenLevel: [String: Int] = [:]

    // MARK: Lifecycle

    func start(_ media: XMedia, title: String? = nil, caption: String? = nil) {
        if mediaId == media.id {
            player.play()
            startTicker()
            // `stop()` dropped Now Playing when the page was left: restore it.
            if backgroundSession {
                registerRemoteCommands()
                updateNowPlaying(force: true)
            }
            return
        }
        stop()
        mediaId = media.id
        retriedNetworkFailure = false
        endedFlag = false
        loading = true
        buffered = 0
        failed = nil
        position = 0
        duration = 0
        scrubTarget = nil
        levels = media.variants
            .filter { $0.contentType == "video/mp4" }
            .sorted { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        guard !levels.isEmpty else {
            failed = "Video unavailable"
            return
        }
        let level = Self.chosenLevel[media.id] ?? pickLevel()
        Self.chosenLevel[media.id] = level
        player.replaceCurrentItem(with: AVPlayerItem(url: levels[level].url))
        player.volume = 1
        // GIFs loop (the page seeks back on the end notification): never pausing at
        // the end keeps the system player's end-of-video controls from popping up.
        player.actionAtItemEnd = media.type == .gif ? .none : .pause
        self.title = title
        self.caption = caption
        startTicker()

        // Videos with sound play like music: the long-form audio session keeps
        // them going with the wrist down / in the background. GIFs are silent.
        guard media.type == .video else {
            player.play()
            return
        }
        let id = media.id
        BackgroundAudio.activate { [weak self] background in
            guard let self, self.mediaId == id else {
                // The viewer went away while the session was still activating (the
                // route picker can take seconds): nothing else would ever turn it off.
                if background { BackgroundAudio.deactivate() }
                return
            }
            self.backgroundSession = background
            self.player.play()
            if background {
                self.registerRemoteCommands()
                self.updateNowPlaying(force: true)
            }
        }
    }

    /// The best variant the measured link carries with headroom; with no recent
    /// measurement, one step above the lowest (never a blurry 240p by default).
    private func pickLevel() -> Int {
        let fallback = levels.count >= 3 ? 1 : 0
        guard let bytesPerSecond = LinkBudget.bytesPerSecond, bytesPerSecond * 8 > 8_000 else { return fallback }
        let bitsPerSecond = bytesPerSecond * 8
        var best = 0
        for (i, v) in levels.enumerated() where Double(v.bitrate ?? 0) * 1.5 <= bitsPerSecond {
            best = i
        }
        return best
    }

    /// Leaving the page (swiping to another attachment): pause and stop advertising a
    /// playback that is not happening. The audio session stays up so coming back keeps
    /// background audio; `teardown` (the viewer closing) releases it.
    func stop() {
        ticker?.cancel()
        ticker = nil
        player.pause()
        if backgroundSession { clearNowPlaying() }
    }

    /// A failure the reader can clear by tapping the message.
    func retry() {
        retriedNetworkFailure = true      // one automatic retry, then only taps
        reloadItem()
    }

    /// Rebuilds the item at the level already chosen for this post. A fresh item
    /// is what clears a network error: AVPlayer does not recover one by itself.
    private func reloadItem() {
        guard let mediaId, !levels.isEmpty else { return }
        retryTask?.cancel()
        retryTask = nil
        let level = Self.chosenLevel[mediaId] ?? pickLevel()
        Self.chosenLevel[mediaId] = level
        failed = nil
        loading = true
        buffered = 0
        duration = 0
        position = 0
        scrubTarget = nil
        player.replaceCurrentItem(with: AVPlayerItem(url: levels[level].url))
        player.play()
        startTicker()
    }

    /// Called by the view when the page goes away for good.
    func teardown() {
        stop()
        retryTask?.cancel()
        retryTask = nil
        player.replaceCurrentItem(with: nil)
        mediaId = nil
        loading = true
        clearNowPlaying()
        if backgroundSession {
            backgroundSession = false
            BackgroundAudio.deactivate()
        }
    }

    // MARK: Now Playing (watch Now Playing app, Bluetooth controls)

    private func registerRemoteCommands() {
        guard commandTokens.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor (VideoPlayback) -> Void) {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                    self.updateNowPlaying(force: true)
                }
                return .success
            }
            commandTokens.append((command, token))
        }
        on(center.playCommand) { $0.resume() }
        on(center.pauseCommand) { $0.player.pause() }
        on(center.togglePlayPauseCommand) { $0.togglePlayPause() }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        on(center.skipForwardCommand) { _ = $0.scrub(bySeconds: 15) }
        on(center.skipBackwardCommand) { _ = $0.scrub(bySeconds: -15) }
    }

    private func resume() {
        if endedFlag { replay() } else { player.play() }
    }

    private func updateNowPlaying(force: Bool = false) {
        guard backgroundSession else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastNowPlaying) > 4 else { return }
        lastNowPlaying = now
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title ?? "Video",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: player.rate > 0 ? 1.0 : 0.0,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let caption, !caption.isEmpty {
            let line = caption.split(whereSeparator: { $0.isNewline }).joined(separator: " ")
            info[MPMediaItemPropertyArtist] = String(line.prefix(120))
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func clearNowPlaying() {
        for (command, token) in commandTokens { command.removeTarget(token) }
        commandTokens.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Controls

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if endedFlag { replay() } else { player.play() }
        }
        isPlaying = player.timeControlStatus == .playing || player.rate > 0
    }

    func replay() {
        endedFlag = false
        scrubTarget = nil
        player.seek(to: .zero)
        player.play()
    }

    func markEnded() {
        endedFlag = true
    }

    /// Scrub by a number of seconds (positive = forward), clamped to the video.
    /// Returns the new target position.
    @discardableResult
    func scrub(bySeconds seconds: Double) -> Double {
        guard duration > 0 else { return position }
        endedFlag = false
        let from = scrubTarget ?? position
        let target = min(max(0, from + seconds), max(0, duration - 0.2))
        scrubTarget = target
        position = target
        seekToken += 1
        let token = seekToken
        // A little tolerance: exact seeks on a streamed MP4 are slow and queue up.
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekToken == token else { return }
                self.scrubTarget = nil
            }
        }
        return target
    }

    // MARK: Progress

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                // 4 Hz only while the clock moves: a paused or ended page has nothing
                // to report, and every @Published write re-renders the page.
                let interval: UInt64 = (self?.isPlaying ?? false) || (self?.loading ?? false) ? 250_000_000 : 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            let error = item.error as NSError?
            let network = error?.domain == NSURLErrorDomain
            if network, !retriedNetworkFailure, mediaId != nil, !levels.isEmpty {
                retriedNetworkFailure = true
                retryTask?.cancel()
                retryTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    self?.reloadItem()
                }
                return
            }
            if failed == nil {
                failed = network ? "Video timed out" : (item.error?.localizedDescription ?? "Video unavailable")
            }
            return
        }

        // Assign only real changes: @Published re-renders on every write, equal or not.
        let length = item.duration.seconds
        if length.isFinite, length > 0, abs(length - duration) > 0.01 { duration = length }
        let now = player.currentTime().seconds
        if scrubTarget == nil, now.isFinite, abs(now - position) > 0.05 { position = now }
        let playing = player.timeControlStatus == .playing
        // Replayed or scrubbed back with the system player's own controls: no
        // longer ended, so a later Play (Now Playing, Bluetooth) must not restart.
        if endedFlag, playing { endedFlag = false }
        if isPlaying != playing {
            isPlaying = playing
            updateNowPlaying(force: true)
        } else {
            updateNowPlaying()
        }

        if length.isFinite, length > 0 {
            let fraction = min(1, max(0, bufferedSeconds(item) / length))
            if abs(fraction - buffered) > 0.01 { buffered = fraction }
        }

        // "Playing" is reported a moment before the first frame is on screen;
        // keep the poster until the clock has really moved, so the reader never
        // sees the player's black frame.
        if loading, playing, now > 0.15 { loading = false }
    }

    private func bufferedSeconds(_ item: AVPlayerItem) -> Double {
        item.loadedTimeRanges.compactMap { $0.timeRangeValue }
            .map { CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) }
            .max() ?? 0
    }
}

/// The long-form audio session that lets a video keep playing in the
/// background (watchOS routes it to Bluetooth headphones/speakers and shows
/// its own route picker when none is connected).
@MainActor
enum BackgroundAudio {
    /// Calls `then(true)` once the long-form session is active, or `then(false)`
    /// when background playback is off or could not start (the reader closed
    /// the route picker, no Bluetooth output): the video then plays as before,
    /// in the foreground only.
    static func activate(then: @escaping @MainActor (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        guard UserDefaults.standard.bool(forKey: PerchSettings.backgroundVideo) else {
            then(false)
            return
        }
        do {
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
        } catch {
            then(false)
            return
        }
        session.activate(options: []) { ok, _ in
            Task { @MainActor in
                if !ok { try? session.setCategory(.soloAmbient) }
                then(ok)
            }
        }
    }

    static func deactivate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(.soloAmbient)
    }
}
