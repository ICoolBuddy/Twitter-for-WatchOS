import Foundation
import Combine
import XKit

/// Offline copies of posts: the post's JSON, its avatar, its photos and its
/// video (lowest-bitrate MP4). Stored in Application Support (not Caches, which
/// the system may purge), so a saved post survives offline for good.
///
/// The post is listed immediately with its text; attachments download in a
/// background task and appear as they land.
@MainActor
final class SavedStore: ObservableObject {
    struct SavedPost: Codable, Identifiable, Equatable {
        var tweet: XTweet
        var savedAt: Date
        var avatarFile: String?
        /// Parallel to `tweet.displayed.media`; "" for videos.
        var mediaFiles: [String] = []
        var videoFile: String?

        var id: String { tweet.id }
    }

    static let shared = SavedStore()

    @Published private(set) var items: [SavedPost] = []
    /// Ids whose attachments are still downloading.
    @Published private(set) var saving: Set<String> = []

    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("saved.json") }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("PerchSaved", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Queries

    func isSaved(_ id: String) -> Bool { items.contains { $0.id == id } }

    func fileURL(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func photoFile(_ post: SavedPost, index: Int) -> String? {
        guard post.mediaFiles.indices.contains(index) else { return nil }
        let name = post.mediaFiles[index]
        return name.isEmpty ? nil : name
    }

    // MARK: Save / remove

    func toggle(_ tweet: XTweet) {
        if isSaved(tweet.id) {
            remove(tweet.id)
        } else {
            save(tweet)
        }
    }

    func remove(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let post = items.remove(at: i)
        saving.remove(id)
        for name in ([post.avatarFile, post.videoFile].compactMap { $0 } + post.mediaFiles) where !name.isEmpty {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        persist()
    }

    private func save(_ tweet: XTweet) {
        let t = tweet.displayed
        let initial = SavedPost(tweet: tweet, savedAt: Date(), avatarFile: nil, mediaFiles: [], videoFile: nil)
        // Text is available offline right away; attachments follow.
        items.insert(initial, at: 0)
        persist()
        saving.insert(tweet.id)

        Task {
            var working = initial
            if let avatar = t.author.avatarURL,
               let name = await fetch(avatar, as: "avatar-\(tweet.id).jpg") {
                working.avatarFile = name
            }

            var files: [String] = []
            for (index, media) in t.media.enumerated() {
                if media.type == .photo {
                    let name = await fetch(media.fullURL, as: "img-\(tweet.id)-\(index).jpg")
                    files.append(name ?? "")
                } else {
                    files.append("")
                    if working.videoFile == nil,
                       let url = media.lowestBitrateMP4 ?? media.playbackURL(maxBitrate: 0),
                       let name = await fetch(url, as: "video-\(tweet.id).mp4") {
                        working.videoFile = name
                    }
                }
            }
            working.mediaFiles = files
            update(working)
            saving.remove(tweet.id)
        }
    }

    private func update(_ post: SavedPost) {
        guard let i = items.firstIndex(where: { $0.id == post.id }) else { return }
        items[i] = post
        persist()
    }

    private func fetch(_ url: URL, as name: String) async -> String? {
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return name }
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? FileManager.default.removeItem(at: temporary)
                return nil
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return name
        } catch {
            return nil
        }
    }

    // MARK: Index

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([SavedPost].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        let snapshot = items
        let url = indexURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
