import Foundation
import XKit

/// Small JSON cache for things the feed cache does not cover: opened posts
/// (threads) and profiles. Stored in Application Support so a post you read or a
/// profile you visited still opens with no connection.
enum OfflineCache {
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
        DispatchQueue.global(qos: .utility).async {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func load<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
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
