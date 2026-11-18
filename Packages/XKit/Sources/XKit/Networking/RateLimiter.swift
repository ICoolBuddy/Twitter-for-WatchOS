import Foundation

/// Keeps Perch behaving like a light human user:
/// - a small minimum gap between requests,
/// - exponential backoff after 429s (honouring `x-rate-limit-reset`),
/// - no request is sent while backing off.
public actor RateLimiter {
    /// One limiter for the whole app: rebuilding the client must not forget a backoff.
    public static let shared = RateLimiter()

    /// Keyed "<account id>/<operation>": X limits each endpoint per account, so one
    /// throttled operation must not block the others. The politeness gap stays global.
    private var blockedUntil: [String: Date] = [:]
    private var consecutive429: [String: Int] = [:]
    private var lastRequest: Date = .distantPast
    private let minimumGap: TimeInterval

    public init(minimumGap: TimeInterval = 0.35) { self.minimumGap = minimumGap }

    /// Throws `.rateLimited` if we are backing off, otherwise waits out the minimum gap.
    public func acquire(key: String = "", now: Date = Date()) async throws {
        if let until = blockedUntil[key], until > now { throw XError.rateLimited(until: until) }
        let wait = minimumGap - now.timeIntervalSince(lastRequest)
        lastRequest = now.addingTimeInterval(max(0, wait))
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }

    @discardableResult
    public func didReceive(key: String = "", status: Int, resetEpoch: TimeInterval?, now: Date = Date()) -> Date? {
        if status == 429 {
            let n = (consecutive429[key] ?? 0) + 1
            consecutive429[key] = n
            let backoff = min(60.0 * pow(2.0, Double(n - 1)), 15 * 60)
            var until = now.addingTimeInterval(backoff)
            if let reset = resetEpoch, reset > now.timeIntervalSince1970 {
                until = max(until, Date(timeIntervalSince1970: reset))
            }
            blockedUntil[key] = until
            return until
        }
        if (200..<300).contains(status) { consecutive429[key] = nil; blockedUntil[key] = nil }
        return nil
    }

    /// The latest backoff of any operation (diagnostics).
    public var backoffUntil: Date? { blockedUntil.values.max() }
    public func reset() { blockedUntil = [:]; consecutive429 = [:] }
}
