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
        var tooLarge = false
        let monitorID: UUID
        /// Host of the original request: a redirect that leaves it must not carry the
        /// session Cookie/ct0 headers to another host.
        let originHost: String
        let continuation: CheckedContinuation<(Data, URLResponse), Error>
    }

    /// Bodies are held whole in memory; on a 1 GB Watch a runaway/captive page must not
    /// be able to grow without bound.
    private static let maxBodyBytes = 8 * 1024 * 1024

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
                pending[task.taskIdentifier] = Pending(monitorID: monitorID,
                                                       originHost: request.url?.host?.lowercased() ?? "",
                                                       continuation: cont)
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
        // Only an optimisation (larger bodies still append); the size is server-chosen,
        // so keep the up-front reservation small on a 1 GB Watch.
        if expected > 0, expected < 2 * 1024 * 1024 {
            pending[dataTask.taskIdentifier]?.data.reserveCapacity(Int(expected))
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var overflow = false
        if var entry = pending[dataTask.taskIdentifier] {
            if entry.data.count + data.count > Self.maxBodyBytes {
                entry.data.removeAll(keepingCapacity: false)
                entry.tooLarge = true
                pending[dataTask.taskIdentifier] = entry
                overflow = true
            } else {
                entry.data.append(data)
                pending[dataTask.taskIdentifier] = entry
            }
        }
        let monitorID = pending[dataTask.taskIdentifier]?.monitorID
        lock.unlock()
        if let monitorID { TransferMonitor.shared.add(data.count, to: monitorID) }
        if overflow { dataTask.cancel() }
    }

    /// Refuse a cross-host redirect: `URLSession` forwards headers we set ourselves
    /// (`Cookie`, `x-csrf-token`) to the redirect target — it only strips
    /// `Authorization` — so a login/anti-bot redirect would hand the session to another
    /// host. Delivering the 3xx instead lets the caller report a real failure.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        let origin = pending[task.taskIdentifier]?.originHost
        lock.unlock()
        let target = request.url?.host?.lowercased() ?? ""
        if let origin, !origin.isEmpty, target != origin {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let done = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let done else { return }
        if done.tooLarge {
            done.continuation.resume(throwing: XError.network("Response too large (max \(Self.maxBodyBytes / (1024 * 1024)) MB)"))
            return
        }
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
    case forbidden(String)         // 403 — locked account, outdated feature switches…
    /// 403/353 that survived the csrf retry: the signing material is the suspect, not
    /// the query IDs, so the remedy is a new signing key.
    case transactionRejected(String)
    /// The active account changed while the request was being retried.
    case accountChanged
    case notFound                  // 404 — usually a stale GraphQL query ID
    case rateLimited(until: Date?) // 429
    case server(Int)
    case network(String)
    case graphQL([String])
    case missingOperation(String)
    case decoding(String)
    /// X answered but its schema no longer matches the query (code 336 / HTTP 422):
    /// retrying cannot help, the query IDs or variables must be refreshed.
    case schemaChanged(String)

    public var errorDescription: String? {
        switch self {
        case .notLoggedIn: return "Not logged in. Log in on your iPhone."
        case .unauthorized: return "Your X session expired. Please log in again."
        case .forbidden(let m): return "X refused the request (403). \(m)"
        case .transactionRejected(let m): return "X rejected the request signature (403). \(m)"
        case .accountChanged: return "The account changed while loading."
        case .notFound: return "This X endpoint has changed (404). Refresh endpoints."
        case .rateLimited(let until):
            if let until { return "Rate limited by X. Try again \(RelativeTime.short(until, future: true))." }
            return "Rate limited by X. Try again later."
        case .server(let c): return "X server error (\(c))."
        case .network(let m): return "Network error: \(m)"
        case .graphQL(let m): return m.first ?? "X returned an error."
        case .missingOperation(let op): return "No query ID known for \(op). Refresh endpoints."
        case .decoding(let m): return "Couldn't read X's response: \(m)"
        case .schemaChanged(let m): return "X changed its API (\(m)). Refresh endpoints."
        }
    }

    /// One remedy per error, decided where the evidence is (XKit), so the UI never has
    /// to try several.
    public enum Recovery: Sendable { case relogin, refreshMaterial, refreshEndpoints, wait, retry }

    public var recovery: Recovery {
        switch self {
        case .notLoggedIn, .unauthorized: return .relogin
        case .transactionRejected: return .refreshMaterial
        case .forbidden, .schemaChanged: return .refreshEndpoints
        case .notFound, .missingOperation: return .refreshEndpoints
        case .rateLimited: return .wait
        default: return .retry
        }
    }

    /// Classifies a **2xx** GraphQL body. X reports real failures in the body while the
    /// HTTP status stays 200, so a success-shaped response can still mean "your session
    /// died" (code 32), "rate limited" (88) or "the schema moved" (336).
    ///
    /// Rules, deliberately conservative:
    /// - auth / rate / schema codes are always an error, even with a non-empty `data`
    ///   (`ViewerBadgeCounts` answers `data: {viewer_v2: {}}` plus code 32);
    /// - any other code is an error when there is no data, or when the caller is a
    ///   mutation (a mutation that reports errors did not do what was asked);
    /// - an unknown code with data on a read is a soft error: X sends them alongside
    ///   usable timeline data, so reads keep working.
    public static func graphQLBodyError(codes: [Int], messages: [String], hasData: Bool,
                                        isMutation: Bool) -> XError? {
        guard !codes.isEmpty || !messages.isEmpty else { return nil }
        let text = messages.first ?? "X returned an error."
        // 32 not authenticated, 89 invalid/expired token, 215 bad authentication data.
        if codes.contains(32) || codes.contains(89) || codes.contains(215) { return .unauthorized }
        if codes.contains(88) { return .rateLimited(until: nil) }
        if codes.contains(336) { return .schemaChanged(text) }
        if isMutation { return .graphQL(messages.isEmpty ? [text] : messages) }
        if !hasData { return .graphQL(messages.isEmpty ? [text] : messages) }
        return nil
    }

    /// X's "you have already liked/retweeted/bookmarked this" rejection: the wanted
    /// state is already on X, so a retried action must not surface as a failure.
    public var isAlreadyDone: Bool {
        if case .graphQL(let messages) = self {
            return messages.contains { $0.lowercased().contains("already") }
        }
        return false
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
