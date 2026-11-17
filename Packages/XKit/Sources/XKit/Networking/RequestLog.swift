import Foundation

public struct RequestLogEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var date: Date
    public var method: String
    public var path: String
    public var status: Int?
    public var durationMs: Int
    public var note: String

    public init(id: UUID = UUID(), date: Date = Date(), method: String, path: String, status: Int?, durationMs: Int, note: String) {
        self.id = id; self.date = date; self.method = method; self.path = path
        self.status = status; self.durationMs = durationMs; self.note = note
    }
}

/// In-memory ring buffer of recent requests. Everything is redacted on insert:
/// cookie values, csrf tokens and query strings never reach the log.
public actor RequestLog {
    public static let shared = RequestLog()
    private var entries: [RequestLogEntry] = []
    private let capacity: Int

    public init(capacity: Int = 150) { self.capacity = capacity }

    public func record(method: String, url: URL?, status: Int?, durationMs: Int, note: String = "") {
        // Path only; GraphQL variables can contain cursors/user data so drop the query.
        let path = url.map { u in (u.host ?? "") + u.path } ?? "?"
        let e = RequestLogEntry(method: method, path: Redactor.redact(path), status: status,
                                durationMs: durationMs, note: Redactor.redact(String(note.prefix(300))))
        entries.append(e)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    public func all() -> [RequestLogEntry] { entries.reversed() }
    public func clear() { entries.removeAll() }
}
