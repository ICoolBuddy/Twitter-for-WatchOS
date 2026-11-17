import Foundation

/// Keeps Perch behaving like a light human user:
/// - a small minimum gap between requests,
/// - exponential backoff after 429s (honouring `x-rate-limit-reset`),
/// - no request is sent while backing off.
public actor RateLimiter {
    private var blockedUntil: Date?
    private var consecutive429 = 0
    private var lastRequest: Date = .distantPast
    private let minimumGap: TimeInterval

    public init(minimumGap: TimeInterval = 0.35) { self.minimumGap = minimumGap }

    /// Throws `.rateLimited` if we are backing off, otherwise waits out the minimum gap.
    public func acquire(now: Date = Date()) async throws {
        if let until = blockedUntil, until > now { throw XError.rateLimited(until: until) }
        let wait = minimumGap - now.timeIntervalSince(lastRequest)
        lastRequest = now.addingTimeInterval(max(0, wait))
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    public func didReceive(status: Int, resetEpoch: TimeInterval?, now: Date = Date()) -> Date? {
        if status == 429 {
            consecutive429 += 1
            let backoff = min(60.0 * pow(2.0, Double(consecutive429 - 1)), 15 * 60)
            var until = now.addingTimeInterval(backoff)
            if let reset = resetEpoch, reset > now.timeIntervalSince1970 {
                until = max(until, Date(timeIntervalSince1970: reset))
            }
            blockedUntil = until
            return until
        }
        if (200..<300).contains(status) { consecutive429 = 0 }
        return nil
    }

    public var backoffUntil: Date? { blockedUntil }
    public func reset() { blockedUntil = nil; consecutive429 = 0 }
}
