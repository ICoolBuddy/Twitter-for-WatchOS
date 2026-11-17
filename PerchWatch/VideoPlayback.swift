import Foundation
import AVFoundation
import Combine
import XKit

/// YouTube-style adaptive playback for a post's video.
///
/// Playback starts within a second on a small MP4 and streams it (AVPlayer keeps
/// downloading while it plays). While it plays we read the measured bitrate from
/// the access log and step up to better variants as soon as the link comfortably
/// covers them, so the quality climbs instead of waiting for a huge download.
/// The best level reached is remembered per post, so replaying (or reopening)
/// starts where it left off instead of dropping back to the lowest.
@MainActor
final class VideoPlayback: ObservableObject {
    let player = AVPlayer()

    /// 0…1 of the video that is downloaded/buffered (drives the loading bar).
    @Published private(set) var buffered: Double = 0
    /// True until the first frame is playing (thumbnail + bar are shown).
    @Published private(set) var loading = true
    @Published private(set) var failed: String?
    @Published private(set) var endedFlag = false
    /// Playback position / length, for the timestamp under the player.
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false

    private var levels: [XVideoVariant] = []
    private var level = 0
    private var started = false
    private var mediaId: String?
    private var ticker: Task<Void, Never>?
    private var lastUpgrade = Date.distantPast

    /// Best level reached per post, for this app run.
    private static var bestLevel: [String: Int] = [:]

    /// Step up quickly: a little measured headroom is enough, and a short
    /// cooldown lets a fast link climb several levels in the first seconds.
    ///
    /// Every switch swaps the player item and rebuffers (a short stall), so it is
    /// rationed: at most `maxUpgradesPerPlay` per playback, a few seconds apart,
    /// and only with enough buffered video to hide the swap.
    private static let upgradeCooldown: TimeInterval = 6
    private static let upgradeHeadroom = 1.4
    private static let minimumBufferAhead: Double = 4
    private static let maxUpgradesPerPlay = 2
    private var upgradesThisPlay = 0

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
        buffered = 0
        failed = nil
        position = 0
        duration = 0
        started = false
        lastUpgrade = .distantPast
        upgradesThisPlay = 0
        levels = media.variants
            .filter { $0.contentType == "video/mp4" }
            .sorted { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        guard !levels.isEmpty else {
            failed = "Video unavailable"
            return
        }
        // Never go back down to the worst variant once a better one has played:
        // on a replay the picture starts where it ended up last time.
        let remembered = Self.bestLevel[media.id] ?? 0
        // Prefer a step above the very lowest when the ladder allows it, so even
        // the first play is not a blurry 240p.
        let preferred = levels.count >= 3 ? 1 : 0
        load(level: min(max(remembered, preferred), levels.count - 1))
        player.play()
        startTicker()
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
        started = false
        loading = true
    }

    // MARK: Controls

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if endedFlag { replay() } else { player.play() }
        }
    }

    func replay() {
        endedFlag = false
        player.seek(to: .zero)
        player.play()
    }

    func markEnded() {
        endedFlag = true
    }

    /// Scrub by a number of seconds (positive = forward), clamped to the video.
    func scrub(bySeconds seconds: Double) {
        guard duration > 0 else { return }
        endedFlag = false
        let target = min(max(0, position + seconds), max(0, duration - 0.2))
        let time = CMTime(seconds: target, preferredTimescale: 600)
        position = target
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Digital-Crown volume: the player's own gain, since the system volume is
    /// not reachable from an app on watchOS.
    func adjustVolume(by delta: Float) {
        player.volume = min(1, max(0, player.volume + delta))
    }

    var volume: Float { player.volume }

    // MARK: Variant loading

    private func load(level index: Int) {
        guard levels.indices.contains(index) else { return }
        level = index
        player.replaceCurrentItem(with: AVPlayerItem(url: levels[index].url))
    }

    private func upgrade(to index: Int) {
        guard levels.indices.contains(index) else { return }
        let time = player.currentTime()
        let wasPlaying = player.timeControlStatus == .playing
        lastUpgrade = Date()
        upgradesThisPlay += 1
        level = index
        if let mediaId { Self.bestLevel[mediaId] = max(Self.bestLevel[mediaId] ?? 0, index) }
        player.replaceCurrentItem(with: AVPlayerItem(url: levels[index].url))
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self, wasPlaying else { return }
            self.player.play()
        }
    }

    // MARK: Progress / adaptive quality

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 400_000_000)
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
        position = player.currentTime().seconds
        isPlaying = player.timeControlStatus == .playing

        if length.isFinite, length > 0 {
            let end = bufferedSeconds(item)
            buffered = min(1, max(0, end / length))
        }

        if player.timeControlStatus == .playing {
            started = true
            loading = false
        } else if started {
            loading = false
        }

        // Measured throughput of the stream (bits/s). Zero until the first
        // access-log event.
        let observed = item.accessLog()?.events.last?.observedBitrate ?? 0
        guard observed > 0, upgradesThisPlay < Self.maxUpgradesPerPlay,
              levels.indices.contains(level + 1) else { return }

        let next = levels[level + 1]
        let needed = Double(next.bitrate ?? 0)
        let ahead = max(0, bufferedSeconds(item) - position)
        guard needed > 0,
              observed > needed * Self.upgradeHeadroom,
              ahead > Self.minimumBufferAhead,
              Date().timeIntervalSince(lastUpgrade) > Self.upgradeCooldown
        else { return }
        upgrade(to: level + 1)
    }

    private func bufferedSeconds(_ item: AVPlayerItem) -> Double {
        item.loadedTimeRanges.compactMap { $0.timeRangeValue }
            .map { CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) }
            .max() ?? 0
    }
}
