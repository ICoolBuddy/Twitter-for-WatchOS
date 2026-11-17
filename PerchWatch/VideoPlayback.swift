import Foundation
import AVFoundation
import Combine
import XKit

/// YouTube-style adaptive playback for a post's video.
///
/// The lowest-bitrate MP4 is started immediately (so playback begins while the
/// rest is still downloading — AVPlayer streams it), and while it plays we read
/// the measured bitrate from the access log. When the measured rate comfortably
/// covers a higher variant *and* the current one is buffered ahead, the player
/// switches to it at the same position. GIFs have a single variant and just loop.
@MainActor
final class VideoPlayback: ObservableObject {
    let player = AVPlayer()

    /// 0…1 of the video that is downloaded/buffered (drives the loading bar).
    @Published private(set) var buffered: Double = 0
    /// True until the first frame is playing (thumbnail + bar are shown).
    @Published private(set) var loading = true
    /// "SD" / "HD" — shows which variant is playing.
    @Published private(set) var quality: String = ""
    @Published private(set) var failed: String?

    private var levels: [XVideoVariant] = []
    private var level = 0
    private var started = false
    private var mediaId: String?
    private var ticker: Task<Void, Never>?
    private var lastUpgrade = Date.distantPast
    /// Switch up once every few seconds at most, and only with buffer in hand.
    private static let upgradeCooldown: TimeInterval = 5
    private static let minimumBufferAhead: Double = 4

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
        level = 0
        started = false
        lastUpgrade = .distantPast
        levels = media.variants
            .filter { $0.contentType == "video/mp4" }
            .sorted { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
        guard !levels.isEmpty else {
            failed = "Video unavailable"
            return
        }
        load(level: 0)
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

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func replay() {
        endedFlag = false
        player.seek(to: .zero)
        player.play()
    }

    /// True once the video played to its end (view shows a replay button).
    @Published private(set) var endedFlag = false

    func markEnded() {
        endedFlag = true
    }

    // MARK: Variant loading

    private func load(level index: Int) {
        guard levels.indices.contains(index) else { return }
        level = index
        quality = Self.qualityLabel(levels[index])
        let item = AVPlayerItem(url: levels[index].url)
        player.replaceCurrentItem(with: item)
    }

    private func upgrade(to index: Int) {
        guard levels.indices.contains(index) else { return }
        let time = player.currentTime()
        let wasPlaying = player.timeControlStatus == .playing
        lastUpgrade = Date()
        level = index
        quality = Self.qualityLabel(levels[index])
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

        let duration = item.duration.seconds
        let position = player.currentTime().seconds
        if duration.isFinite, duration > 0 {
            let ranges = item.loadedTimeRanges.compactMap { $0.timeRangeValue }
            let end = ranges
                .map { CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) }
                .max() ?? 0
            buffered = min(1, max(0, end / duration))
        }

        if player.timeControlStatus == .playing {
            started = true
            loading = false
        } else if started {
            loading = false
        }

        // Measured throughput of the stream (bits/s). Zero until the first
        // access-log event, or for local files.
        let observed = item.accessLog()?.events.last?.observedBitrate ?? 0
        guard observed > 0, levels.indices.contains(level + 1) else { return }

        let next = levels[level + 1]
        let needed = Double(next.bitrate ?? 0)
        let bufferedAhead = max(0, bufferedSeconds(item) - position)
        guard needed > 0,
              observed > needed * 1.6,
              bufferedAhead > Self.minimumBufferAhead,
              Date().timeIntervalSince(lastUpgrade) > Self.upgradeCooldown
        else { return }
        upgrade(to: level + 1)
    }

    private func bufferedSeconds(_ item: AVPlayerItem) -> Double {
        item.loadedTimeRanges.compactMap { $0.timeRangeValue }
            .map { CMTimeGetSeconds($0.start) + CMTimeGetSeconds($0.duration) }
            .max() ?? 0
    }

    private static func qualityLabel(_ variant: XVideoVariant) -> String {
        guard let bitrate = variant.bitrate, bitrate > 0 else { return "" }
        switch bitrate {
        case ..<400_000: return "SD"
        case ..<1_200_000: return "HD"
        default: return "FHD"
        }
    }
}
