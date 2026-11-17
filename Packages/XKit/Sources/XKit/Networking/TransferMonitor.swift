import Foundation

/// Counts in-flight HTTP requests and recent download throughput so the UI can show a
/// slim "Loading posts · 85 KB/s" status line. Fed by `URLSessionTransport` (per chunk).
public final class TransferMonitor: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var activeRequests: Int
        public var bytesReceived: Int64
        public var bytesPerSecond: Double

        public init(activeRequests: Int, bytesReceived: Int64, bytesPerSecond: Double) {
            self.activeRequests = activeRequests
            self.bytesReceived = bytesReceived
            self.bytesPerSecond = bytesPerSecond
        }
    }

    public static let shared = TransferMonitor()

    /// Throughput is averaged over this window; with no traffic in it the rate is 0.
    private static let window: TimeInterval = 1.5
    /// Don't divide by a tiny span when a download just started.
    private static let minimumSpan: TimeInterval = 0.3

    private struct Event {
        let date: Date
        let bytes: Int64
    }

    private let lock = NSLock()
    private var activeIDs = Set<UUID>()
    private var bytesReceived: Int64 = 0
    private var events: [Event] = []

    public init() {}

    public func begin() -> UUID {
        let id = UUID()
        lock.lock()
        activeIDs.insert(id)
        lock.unlock()
        return id
    }

    public func add(_ bytes: Int, to id: UUID) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        bytesReceived += Int64(bytes)
        let now = Date()
        events.append(Event(date: now, bytes: Int64(bytes)))
        prune(now)
    }

    public func end(_ id: UUID) {
        lock.lock()
        activeIDs.remove(id)
        lock.unlock()
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        prune(now)
        let recent = events.reduce(Int64(0)) { $0 + $1.bytes }
        var rate = 0.0
        if recent > 0, let first = events.first?.date {
            let span = min(Self.window, max(Self.minimumSpan, now.timeIntervalSince(first)))
            rate = Double(recent) / span
        }
        return Snapshot(activeRequests: activeIDs.count, bytesReceived: bytesReceived, bytesPerSecond: rate)
    }

    /// "12 KB/s", "1.2 MB/s" — decimal units, which is what network graphs use.
    public static func formatRate(_ bps: Double) -> String {
        guard bps > 0 else { return "0 KB/s" }
        if bps >= 999_500 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps < 1_000 { return "\(Int(bps.rounded())) B/s" }
        return "\(Int((bps / 1_000).rounded())) KB/s"
    }

    /// Must be called with the lock held.
    private func prune(_ now: Date) {
        events.removeAll { now.timeIntervalSince($0.date) > Self.window }
    }
}
