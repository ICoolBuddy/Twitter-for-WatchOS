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
    /// Cached threads and profiles carry per-account state (liked, reposted, bookmarked,
    /// following), so they are stored per account (`<account>-thread-<id>.json`), like
    /// the timeline caches. Set from `AppModel.onActiveAccountChange`.
    nonisolated(unsafe) private static var namespace = "none"

    static func setNamespace(_ accountId: String?) {
        let next = accountId ?? "none"
        if next != namespace { namespace = next }
    }
    /// Resolved once: every profile/thread open used to stat the filesystem on main.
    private static let directory: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("PerchOffline", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private static func url(_ name: String) -> URL? {
        directory?.appendingPathComponent(namespace + "-" + name + ".json")
    }

    static func save<T: Encodable>(_ value: T, name: String) {
        guard let url = url(name) else { return }
        DiskWriter.queue.async {
            // Encoded on the queue too: a thread page is up to a few hundred KB, and this
            // used to run on the main thread for every page of every post.
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: .atomic)
            trimIfNeeded(url.deletingLastPathComponent())
        }
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// `load` off the main thread: opening a screen must not stall on its cache.
    /// The URL (namespace included) is resolved on the caller: the namespace is written
    /// on the main actor, and the old code read it from the disk queue (a data race that
    /// could also load another account's cache).
    static func loadAsync<T: Decodable>(_ type: T.Type, name: String) async -> T? {
        guard let url = url(name) else { return nil }
        return await withCheckedContinuation { continuation in
            DiskWriter.queue.async {
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil); return
                }
                continuation.resume(returning: try? JSONDecoder().decode(T.self, from: data))
            }
        }
    }

    /// Runs on `DiskWriter.queue`; scans the folder at most once a minute.
    nonisolated(unsafe) private static var lastTrim = Date.distantPast

    private static func trimIfNeeded(_ dir: URL) {
        let now = Date()
        guard now.timeIntervalSince(lastTrim) > 60 else { return }
        lastTrim = now
        DiskWriter.trim(dir, prefix: "", keep: maxFiles)
    }

    /// An account was removed: nothing it cached may be read again.
    static func clear(accountId: String) {
        guard let dir = directory else { return }
        let prefix = accountId + "-"
        DiskWriter.queue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for f in files where f.lastPathComponent.hasPrefix(prefix) { try? fm.removeItem(at: f) }
        }
    }

    /// Logout: cached threads/profiles of every account belong to the old session.
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
            // Pre-namespace files ("thread-…", "user-…", "handle-…") carry whichever
            // account's state cached them; they are unreadable now, so drop them.
            if let dir = directory,
               let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in files where ["thread-", "user-", "handle-"].contains(where: { f.lastPathComponent.hasPrefix($0) }) {
                    try? FileManager.default.removeItem(at: f)
                }
            }
        }
    }

    // MARK: Posts

    static func thread(id: String) async -> ThreadPage? {
        await loadAsync(ThreadPage.self, name: "thread-" + id)
    }

    static func save(_ page: ThreadPage, id: String) {
        save(page, name: "thread-" + id)
    }

    // MARK: Profiles

    static func user(id: String?) async -> XUser? {
        guard let id, !id.isEmpty else { return nil }
        return await loadAsync(XUser.self, name: "user-" + id)
    }

    static func user(screenName: String?) async -> XUser? {
        guard let screenName, !screenName.isEmpty else { return nil }
        return await loadAsync(XUser.self, name: "handle-" + screenName.lowercased())
    }

    static func save(_ user: XUser) {
        save(user, name: "user-" + user.id)
        save(user, name: "handle-" + user.screenName.lowercased())
    }
}
