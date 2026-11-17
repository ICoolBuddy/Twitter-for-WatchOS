import Foundation
import XKit

/// Small JSON cache for things the feed cache does not cover: opened posts
/// (threads) and profiles. Stored in Application Support so a post you read or a
/// profile you visited still opens with no connection.
///
/// Bounded: only the most recently written `maxFiles` entries are kept (oldest
/// first out), because Watch storage is small.
enum OfflineCache {
    static let maxFiles = 200
    private static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("PerchOffline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func url(_ name: String) -> URL? {
        directory?.appendingPathComponent(name + ".json")
    }

    static func save<T: Encodable>(_ value: T, name: String) {
        guard let url = url(name), let data = try? JSONEncoder().encode(value) else { return }
        DiskWriter.queue.async {
            try? data.write(to: url, options: .atomic)
            trimIfNeeded(url.deletingLastPathComponent())
        }
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Runs on `DiskWriter.queue`; scans the folder at most once a minute.
    nonisolated(unsafe) private static var lastTrim = Date.distantPast

    private static func trimIfNeeded(_ dir: URL) {
        let now = Date()
        guard now.timeIntervalSince(lastTrim) > 60 else { return }
        lastTrim = now
        DiskWriter.trim(dir, prefix: "", keep: maxFiles)
    }

    /// Logout: cached threads/profiles belong to the old session.
    static func clear() {
        guard let dir = directory else { return }
        DiskWriter.queue.async { try? FileManager.default.removeItem(at: dir) }
    }

    /// Older builds downloaded videos into `Caches/perch-video` and never deleted
    /// them; the viewer streams now, so the folder is only dead weight.
    static func removeLegacyFiles() {
        DiskWriter.queue.async {
            guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
            let legacy = caches.appendingPathComponent("perch-video", isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.path) {
                try? FileManager.default.removeItem(at: legacy)
            }
        }
    }

    // MARK: Posts

    static func thread(id: String) -> ThreadPage? {
        load(ThreadPage.self, name: "thread-" + id)
    }

    static func save(_ page: ThreadPage, id: String) {
        save(page, name: "thread-" + id)
    }

    // MARK: Profiles

    static func user(id: String?) -> XUser? {
        guard let id, !id.isEmpty else { return nil }
        return load(XUser.self, name: "user-" + id)
    }

    static func user(screenName: String?) -> XUser? {
        guard let screenName, !screenName.isEmpty else { return nil }
        return load(XUser.self, name: "handle-" + screenName.lowercased())
    }

    static func save(_ user: XUser) {
        save(user, name: "user-" + user.id)
        save(user, name: "handle-" + user.screenName.lowercased())
    }
}
