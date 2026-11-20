import Foundation
import XKit

/// The one place that answers "can this link carry N bytes in time?". The feed
/// prefetch count, the full-size photo decision and the video quality level all ask
/// it, so the thresholds and the "no measurement yet" policy live in one file (three
/// copies had three different ideas of what a rate of 0 meant).
enum LinkBudget {
    /// Typical JPEG bytes per pixel for the images X serves.
    static let bytesPerPixel = 0.2
    /// Below this the link is a slow (Bluetooth-relayed) one.
    static let slowBytesPerSecond = 40_000.0

    /// Measured throughput over the last moments (API calls and image downloads);
    /// nil when there is no recent sample — "nothing measured", not "no bandwidth".
    static var bytesPerSecond: Double? {
        let rate = TransferMonitor.shared.snapshot().bytesPerSecond
        return rate > 1 ? rate : nil
    }

    /// True when `bytes` would take longer than `seconds`, or when the speed is simply
    /// unknown (cold start): callers stay conservative then.
    static func isTooSlow(bytes: Double, seconds: Double) -> Bool {
        guard let rate = bytesPerSecond else { return true }
        return bytes / rate > seconds
    }

    /// How many posts of a feed page to warm images for.
    static var prefetchPostCount: Int {
        guard let rate = bytesPerSecond else { return 6 }     // unknown: a handful
        // A fast link used to warm 40 posts; on the 150 pt viewport that decodes far
        // more than the cache holds and evicts the images actually on screen.
        return rate < slowBytesPerSecond ? 4 : 14
    }
}
