import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession transport with cookie handling disabled: XKit sets the
/// `Cookie` header itself so nothing is persisted outside the Keychain.
///
/// Responses arrive in chunks through `ChunkedDataDelegate`, which feeds
/// `TransferMonitor` (progress / throughput) without iterating the body one
/// byte at a time (`URLSession.AsyncBytes` is very slow for that on the Watch).
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession
    #if canImport(Darwin)
    private let chunks: ChunkedDataDelegate?
    #endif

    /// Default transport: a cookie-less ephemeral session with chunked progress.
    public init() {
        #if canImport(Darwin)
        // One shared session: a session keeps its delegate alive until it is
        // invalidated, so one per client (rebuilt on every account switch) or per
        // helper (discovery, material fetch) would only pile up.
        self.chunks = Self.shared.delegate
        self.session = Self.shared.session
        #else
        self.session = URLSessionTransport.makeSession()
        #endif
    }

    #if canImport(Darwin)
    private static let shared: (session: URLSession, delegate: ChunkedDataDelegate) = {
        let delegate = ChunkedDataDelegate()
        let session = URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: nil)
        return (session, delegate)
    }()
    #endif

    /// Custom session (tests): plain `data(for:)`, bytes are counted at the end.
    public init(session: URLSession) {
        self.session = session
        #if canImport(Darwin)
        self.chunks = nil
        #endif
    }

    public static func makeConfiguration(timeout: TimeInterval = 30) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieAcceptPolicy = .never
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 3
        cfg.httpMaximumConnectionsPerHost = 4
        return cfg
    }

    public static func makeSession(timeout: TimeInterval = 30) -> URLSession {
        URLSession(configuration: makeConfiguration(timeout: timeout))
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(Darwin)
        let id = TransferMonitor.shared.begin()
        defer { TransferMonitor.shared.end(id) }
        let data: Data
        let response: URLResponse
        if let chunks {
            (data, response) = try await chunks.load(request, in: session, monitorID: id)
        } else {
            (data, response) = try await session.data(for: request)
            TransferMonitor.shared.add(data.count, to: id)
        }
        guard let http = response as? HTTPURLResponse else { throw XError.network("Not an HTTP response") }
        return (data, http)
        #else
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XError.network("Not an HTTP response") }
        return (data, http)
        #endif
    }
}

#if canImport(Darwin)
/// Collects data-task bodies chunk by chunk and resumes the waiting caller when
/// the task completes. One instance serves every task of its session.
final class ChunkedDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var data = Data()
        var response: URLResponse?
        let monitorID: UUID
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
    }

    /// Holds the task so cancellation can reach it from another thread.
    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func set(_ t: URLSessionTask) {
            lock.lock()
            task = t
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled { t.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let t = task
            lock.unlock()
            t?.cancel()
        }
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]

    func load(_ request: URLRequest, in session: URLSession, monitorID: UUID) async throws -> (Data, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: request)
                lock.lock()
                pending[task.taskIdentifier] = Pending(monitorID: monitorID, continuation: cont)
                lock.unlock()
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.response = response
        let expected = response.expectedContentLength
        if expected > 0, expected < 32 * 1024 * 1024 {
            pending[dataTask.taskIdentifier]?.data.reserveCapacity(Int(expected))
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.data.append(data)
        let monitorID = pending[dataTask.taskIdentifier]?.monitorID
        lock.unlock()
        if let monitorID { TransferMonitor.shared.add(data.count, to: monitorID) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let done = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let done else { return }
        if let error {
            done.continuation.resume(throwing: error)
        } else if let response = done.response ?? task.response {
            done.continuation.resume(returning: (done.data, response))
        } else {
            done.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}
#endif

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
        // A 403 is almost always a missing/stale transaction id or feature
        // flags, not an expired session (that is a 401).
        case .forbidden: return .refreshEndpoints
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
    /// Created once: a `DateFormatter` per row render is expensive on the Watch.
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    private static let formatterLock = NSLock()

    public static func short(_ date: Date, now: Date = Date(), future: Bool = false) -> String {
        let s = Int(abs(now.timeIntervalSince(date)))
        let v: String
        switch s {
        case ..<60: v = "\(s)s"
        case ..<3600: v = "\(s / 60)m"
        case ..<86400: v = "\(s / 3600)h"
        case ..<(86400 * 7): v = "\(s / 86400)d"
        default:
            formatterLock.lock()
            defer { formatterLock.unlock() }
            return formatter.string(from: date)
        }
        return future ? "in " + v : v
    }
}
