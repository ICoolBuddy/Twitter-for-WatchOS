import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession transport with cookie handling disabled: XKit sets the
/// `Cookie` header itself so nothing is persisted outside the Keychain.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = URLSessionTransport.makeSession()) { self.session = session }

    public static func makeSession(timeout: TimeInterval = 30) -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 3
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(Darwin)
        // Stream the response so the UI can show progress / throughput while it downloads.
        let id = TransferMonitor.shared.begin()
        defer { TransferMonitor.shared.end(id) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw XError.network("Not an HTTP response") }
        var data = Data()
        if http.expectedContentLength > 0, http.expectedContentLength < Int64(Int.max) {
            data.reserveCapacity(Int(http.expectedContentLength))
        }
        var chunk = [UInt8]()
        chunk.reserveCapacity(16 * 1024)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 16 * 1024 {
                TransferMonitor.shared.add(chunk.count, to: id)
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            TransferMonitor.shared.add(chunk.count, to: id)
            data.append(contentsOf: chunk)
        }
        return (data, http)
        #else
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XError.network("Not an HTTP response") }
        return (data, http)
        #endif
    }
}

public enum XError: Error, Sendable, Equatable, LocalizedError {
    case notLoggedIn
    case unauthorized              // 401 — session expired / logged out
    case forbidden(String)         // 403 — csrf mismatch, locked account, missing transaction id…
    case notFound                  // 404 — usually a stale GraphQL query ID
    case rateLimited(until: Date?) // 429
    case server(Int)
    case network(String)
    case graphQL([String])
    case missingOperation(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not logged in. Log in on your iPhone."
        case .unauthorized: return "Your X session expired. Please log in again."
        case .forbidden(let m): return "X refused the request (403). \(m)"
        case .notFound: return "This X endpoint has changed (404). Refresh endpoints."
        case .rateLimited(let until):
            if let until { return "Rate limited by X. Try again \(RelativeTime.short(until, future: true))." }
            return "Rate limited by X. Try again later."
        case .server(let c): return "X server error (\(c))."
        case .network(let m): return "Network error: \(m)"
        case .graphQL(let m): return m.first ?? "X returned an error."
        case .missingOperation(let op): return "No query ID known for \(op). Refresh endpoints."
        case .decoding(let m): return "Couldn't read X's response: \(m)"
        }
    }

    public enum Recovery: Sendable { case relogin, refreshEndpoints, wait, retry }

    public var recovery: Recovery {
        switch self {
        case .notLoggedIn, .unauthorized: return .relogin
        case .forbidden: return .relogin
        case .notFound, .missingOperation: return .refreshEndpoints
        case .rateLimited: return .wait
        default: return .retry
        }
    }

    public static func from(_ error: Error) -> XError {
        if let x = error as? XError { return x }
        if error is CancellationError { return .network("Cancelled") }
        return .network(error.localizedDescription)
    }
}

/// Tiny relative-time formatter suited to small screens ("3m", "2h", "5d").
public enum RelativeTime {
    public static func short(_ date: Date, now: Date = Date(), future: Bool = false) -> String {
        let s = Int(abs(now.timeIntervalSince(date)))
        let v: String
        switch s {
        case ..<60: v = "\(s)s"
        case ..<3600: v = "\(s / 60)m"
        case ..<86400: v = "\(s / 3600)h"
        case ..<(86400 * 7): v = "\(s / 86400)d"
        default:
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return f.string(from: date)
        }
        return future ? "in " + v : v
    }
}
