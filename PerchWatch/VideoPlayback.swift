import Foundation
import AVFoundation
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
    /// Playing stalled for more data after it had started.
    @Published private(set) var stalled = false
    @Published private(set) var failed: String?
    @Published private(set) var endedFlag = false
    /// Playback position / length, for the timestamp under the player.
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    /// Player gain 0…1 (the crown changes it; the system volume is not reachable).
    @Published private(set) var volume: Float = 1

    private var levels: [XVideoVariant] = []
    private var mediaId: String?
    private var ticker: Task<Void, Never>?
    /// Where an in-flight crown scrub is going. While set, the ticker does not
    /// overwrite `position` with the player's (older) time, so consecutive crown
    /// turns add up instead of snapping back.
    private var scrubTarget: Double?
    private var seekToken = 0

    /// Quality level used per post, for this app run.
    private static var chosenLevel: [String: Int] = [:]

    // MARK: Lifecycle

    func start(_ media: XMedia) {
        if mediaId == media.id {
            player.play()
            return
        }
        stop()
        mediaId = media.id
        endedFlag = false
        loading = true
        stalled = false
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
        player.volume = volume
        player.play()
        startTicker()
    }

    /// The best variant the measured link carries with headroom; with no recent
    /// measurement, one step above the lowest (never a blurry 240p by default).
    private func pickLevel() -> Int {
        let bitsPerSecond = TransferMonitor.shared.snapshot().bytesPerSecond * 8
        let fallback = levels.count >= 3 ? 1 : 0
        guard bitsPerSecond > 8_000 else { return fallback }
        var best = 0
        for (i, v) in levels.enumerated() where Double(v.bitrate ?? 0) * 1.5 <= bitsPerSecond {
            best = i
        }
        return best
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player.pause()
    }

    /// Called by the view when the page goes away for good.
    func teardown() {
        stop()
        player.replaceCurrentItem(with: nil)
        mediaId = nil
        loading = true
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

    func setVolume(_ value: Float) {
        volume = min(1, max(0, value))
        player.volume = volume
    }

    // MARK: Progress

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        guard let item = player.currentItem else { return }
        if item.status == .failed {
            failed = item.error?.localizedDescription ?? "Video unavailable"
            return
        }

        let length = item.duration.seconds
        if length.isFinite, length > 0 { duration = length }
        let now = player.currentTime().seconds
        if scrubTarget == nil, now.isFinite { position = now }
        let playing = player.timeControlStatus == .playing
        if isPlaying != playing { isPlaying = playing }

        if length.isFinite, length > 0 {
            buffered = min(1, max(0, bufferedSeconds(item) / length))
        }

        // "Playing" is reported a moment before the first frame is on screen;
        // keep the poster until the clock has really moved, so the reader never
        // sees the player's black frame.
        if loading, playing, now > 0.15 { loading = false }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if stalled != (!loading && waiting) { stalled = !loading && waiting }
    }

    private func bufferedSeconds(_ item: AVPlayerItem) -> Double {
        item.loadedTimeRanges.compactMap { $0.timeRangeValue }
            .map { CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) }
            .max() ?? 0
    }
}
