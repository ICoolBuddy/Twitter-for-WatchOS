import Foundation
import Combine
import XKit

/// Offline copies of posts: the post's JSON, its avatar, its photos and its
/// video (lowest-bitrate MP4). Stored in Application Support (not Caches, which
/// the system may purge), so a saved post survives offline for good.
///
/// The post is listed immediately with its text; attachments download afterwards
/// (a plain Task while the app runs) and appear as they land.
@MainActor
final class SavedStore: ObservableObject {
    struct SavedPost: Codable, Identifiable, Hashable {
        var tweet: XTweet
        var savedAt: Date
        var avatarFile: String?
        /// Parallel to `tweet.displayed.media`; "" for videos.
        var mediaFiles: [String]
        var videoFile: String?
        /// A still of the video, so the row has a thumbnail with no network.
        var posterFile: String?
        /// Attachment downloads that already failed: a post whose media is gone
        /// (404/403) stops re-downloading on every launch after a few tries.
        var failedAttempts: Int?
        /// Why an attachment is missing (gone, too large, no room); shown in the row.
        var problem: String?

        var id: String { tweet.id }

        init(tweet: XTweet, savedAt: Date, avatarFile: String? = nil,
             mediaFiles: [String] = [], videoFile: String? = nil, posterFile: String? = nil,
             failedAttempts: Int? = nil, problem: String? = nil) {
            self.tweet = tweet
            self.savedAt = savedAt
            self.avatarFile = avatarFile
            self.mediaFiles = mediaFiles
            self.videoFile = videoFile
            self.posterFile = posterFile
            self.failedAttempts = failedAttempts
            self.problem = problem
        }

        private enum CodingKeys: String, CodingKey {
            case tweet, savedAt, avatarFile, mediaFiles, videoFile, posterFile, failedAttempts, problem
        }

        /// Tolerant decode, on purpose. A field added later (`mediaFiles`) is not in an
        /// older entry; with the synthesised decoder that made the *whole entry*
        /// unreadable, and with every entry unreadable the list came back empty — the
        /// reader saw "all saved posts are gone" and a cold boot changed nothing.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tweet = try c.decode(XTweet.self, forKey: .tweet)
            savedAt = (try? c.decode(Date.self, forKey: .savedAt)) ?? .distantPast
            avatarFile = try? c.decodeIfPresent(String.self, forKey: .avatarFile)
            mediaFiles = (try? c.decode([String].self, forKey: .mediaFiles)) ?? []
            videoFile = try? c.decodeIfPresent(String.self, forKey: .videoFile)
            posterFile = try? c.decodeIfPresent(String.self, forKey: .posterFile)
            failedAttempts = try? c.decodeIfPresent(Int.self, forKey: .failedAttempts)
            problem = try? c.decodeIfPresent(String.self, forKey: .problem)
        }
    }

    /// One named constant each (the Watch shares its storage with everything else).
    private enum Limit {
        /// A saved video bigger than this is skipped: a long clip at the lowest MP4
        /// variant is easily 20–40 MB.
        static let videoBytes: Int64 = 25 * 1024 * 1024
        /// Total budget for everything in `PerchSaved`.
        static let totalBytes: Int64 = 250 * 1024 * 1024
        /// Download attempts before a missing attachment is given up on.
        static let attempts = 3
    }

    private enum SaveError: Error {
        case http(Int), tooBig, noRoom
        var message: String {
            switch self {
            case .http(let code): return code == 404 || code == 403 ? "Media no longer available" : "Media unavailable (\(code))"
            case .tooBig: return "Video too large to save"
            case .noRoom: return "Not enough room for saved posts"
            }
        }
    }

    static let shared = SavedStore()

    @Published private(set) var items: [SavedPost] = [] {
        didSet { byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
    }
    /// Fast lookup for feed rows (`localPhoto` runs in every post's body).
    private var byID: [String: SavedPost] = [:]
    /// Ids whose attachments are still downloading.
    @Published private(set) var saving: Set<String> = []
    /// How many entries the index had when it was loaded. An empty in-memory list after
    /// a failed/corrupt load must never be written over a non-empty file.
    private var loadedCount = 0

    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("saved.json") }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("PerchSaved", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        resumeIncomplete()
    }

    /// Attachments still missing (the app was suspended or killed while saving):
    /// download them again on the next launch, one post at a time (the Watch link is
    /// shared with the feed), unless they already failed for good.
    private func resumeIncomplete() {
        let pending = items.filter { isIncomplete($0) && !isGivenUp($0) }
        guard !pending.isEmpty else { return }
        Task {
            for post in pending where isSaved(post.id) { await downloadNow(post) }
        }
    }

    private func isGivenUp(_ post: SavedPost) -> Bool {
        post.problem != nil && (post.failedAttempts ?? 0) >= Limit.attempts
    }

    private func isIncomplete(_ post: SavedPost) -> Bool {
        let media = post.tweet.displayed.media
        if post.avatarFile == nil, post.tweet.displayed.author.avatarURL != nil { return true }
        if post.mediaFiles.count != media.count { return true }
        for (i, m) in media.enumerated() where m.type == .photo && post.mediaFiles[i].isEmpty { return true }
        if media.contains(where: { $0.type != .photo }), post.videoFile == nil { return true }
        return false
    }

    // MARK: Queries

    func isSaved(_ id: String) -> Bool { byID[id] != nil }

    func fileURL(_ name: String?) -> URL? {
        guard let name, !name.isEmpty else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Local copy of a post's photo, for lists that should not re-download it.
    /// No file-system check here (it runs on the main thread for every feed
    /// row): files in the folder only disappear through `remove`.
    func localPhoto(tweetID: String, index: Int) -> URL? {
        guard let post = byID[tweetID] else { return nil }
        let media = post.tweet.displayed.media
        if media.indices.contains(index), media[index].type != .photo {
            // A video has no photo at its index: its saved still is the thumbnail,
            // so the row looks like a feed row even with no connection.
            guard let poster = post.posterFile else { return nil }
            return directory.appendingPathComponent(poster)
        }
        guard let name = photoFile(post, index: index) else { return nil }
        return directory.appendingPathComponent(name)
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
        for name in ([post.avatarFile, post.videoFile, post.posterFile].compactMap { $0 } + post.mediaFiles) where !name.isEmpty {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        if items.isEmpty { loadedCount = 0 }
        persist()
    }

    private func save(_ tweet: XTweet) {
        let initial = SavedPost(tweet: tweet, savedAt: Date(), avatarFile: nil, mediaFiles: [], videoFile: nil)
        // Text is available offline right away; attachments follow.
        items.insert(initial, at: 0)
        persist()
        Task { await downloadNow(initial) }
    }

    /// Fetches whatever attachments `post` is still missing (files already on disk are
    /// skipped by `fetch`).
    private func downloadNow(_ post: SavedPost) async {
        let tweet = post.tweet
        let t = tweet.displayed
        guard !saving.contains(tweet.id) else { return }
        saving.insert(tweet.id)
        defer { saving.remove(tweet.id) }

        var working = post
        var problem: SaveError?
        var written: [String] = []
        func get(_ url: URL, _ name: String, maxBytes: Int64? = nil) async -> String? {
            do {
                let n = try await fetch(url, as: name, maxBytes: maxBytes)
                written.append(n)
                return n
            } catch let e as SaveError {
                if problem == nil { problem = e }
                return nil
            } catch {
                return nil
            }
        }
        // The feed's `_bigger` copy: the Saved rows show avatars at up to 88 px.
        if let avatar = t.author.avatarLargeURL ?? t.author.avatarURL,
           let name = await get(avatar, "avatar-\(tweet.id).jpg") {
            working.avatarFile = name
        }
        var files: [String] = []
        for (index, media) in t.media.enumerated() {
            if media.type == .photo {
                files.append(await get(media.fullURL, "img-\(tweet.id)-\(index).jpg") ?? "")
            } else {
                files.append("")
                if working.videoFile == nil,
                   let url = media.lowestBitrateMP4 ?? media.playbackURL(maxBitrate: 0),
                   let name = await get(url, "video-\(tweet.id).mp4", maxBytes: Limit.videoBytes) {
                    working.videoFile = name
                }
                // A still for the row. Generating one from the file is not possible on
                // watchOS (AVAssetImageGenerator is unavailable), so save X's own
                // thumbnail JPEG: it is the same image the feed shows.
                if working.posterFile == nil,
                   let poster = await get(media.feedURL, "poster-\(tweet.id).jpg") {
                    working.posterFile = poster
                }
            }
        }
        working.mediaFiles = files
        guard isSaved(tweet.id) else {
            // Removed while downloading: don't leave the files just written behind.
            for name in written { try? FileManager.default.removeItem(at: directory.appendingPathComponent(name)) }
            return
        }
        if isIncomplete(working) {
            if let problem {
                working.failedAttempts = (working.failedAttempts ?? 0) + 1
                // A size/room problem never fixes itself: give up right away.
                if case .tooBig = problem { working.failedAttempts = Limit.attempts }
                if case .noRoom = problem { working.failedAttempts = Limit.attempts }
                working.problem = problem.message
            } else {
                // A network failure is not the post's fault: it must not consume the
                // three attempts (three offline launches used to abandon it for good).
                working.problem = nil
            }
        } else {
            working.failedAttempts = nil
            working.problem = nil
        }
        update(working)
    }


    private func update(_ post: SavedPost) {
        guard let i = items.firstIndex(where: { $0.id == post.id }) else { return }
        items[i] = post
        persist()
    }

    private func fetch(_ url: URL, as name: String, maxBytes: Int64? = nil) async throws -> String {
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { return name }
        // Ask the size before pulling a 200 MB clip over a Bluetooth-relayed link.
        if let maxBytes {
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            if let (_, resp) = try? await URLSession.shared.data(for: head),
               let http = resp as? HTTPURLResponse,
               let raw = http.value(forHTTPHeaderField: "Content-Length"),
               let length = Int64(raw), length > maxBytes {
                throw SaveError.tooBig
            }
        }
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SaveError.http(http.statusCode)
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: temporary.path))?[.size] as? NSNumber)?.int64Value ?? 0
        if let maxBytes, size > maxBytes { throw SaveError.tooBig }
        if size + usedBytes() > Limit.totalBytes { throw SaveError.noRoom }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return name
    }

    /// The budget for everything in `PerchSaved` (for the usage line).
    var budgetBytes: Int64 { Limit.totalBytes }

    /// Retry an attachment that was given up on (after freeing space).
    func retry(_ id: String) {
        guard var post = byID[id] else { return }
        post.failedAttempts = nil
        post.problem = nil
        update(post)
        Task { await downloadNow(post) }
    }

    /// Bytes currently stored in `PerchSaved`.
    func usedBytes() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    // MARK: Index

    private func load() {
        guard let data = try? Data(contentsOf: indexURL), !data.isEmpty else { return }
        do {
            items = try JSONDecoder().decode([SavedPost].self, from: data)
            loadedCount = items.count
            return
        } catch {
            // Name the field that broke: CodingError descriptions carry the key path,
            // and this line is readable in the app's Request log on the Watch.
            Task { await RequestLog.shared.record(method: "-", url: nil, status: nil, durationMs: 0,
                                                 note: "saved.json unreadable: \(error)") }
        }
        // One unreadable entry (an older schema, a truncated write) must not cost the
        // whole list, which the next persist() would then overwrite.
        let decoder = JSONDecoder()
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [Any] ?? []
        items = raw.compactMap { element in
            guard let bytes = try? JSONSerialization.data(withJSONObject: element) else { return nil }
            return try? decoder.decode(SavedPost.self, from: bytes)
        }
        loadedCount = items.count
        let lost = raw.count - items.count
        // Keep the unreadable file: the next persist() writes only the survivors.
        let backup = indexURL.deletingLastPathComponent()
            .appendingPathComponent("saved.corrupt-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.copyItem(at: indexURL, to: backup)
        Task { await RequestLog.shared.record(method: "-", url: nil, status: nil, durationMs: 0,
                                             note: "saved.json: \(lost) unreadable entr\(lost == 1 ? "y" : "ies") skipped (backup kept, \(raw.count) entries were there)") }
    }

    private func persist() {
        // A load that could not read the file leaves `items` empty; writing that back
        // would turn a decode problem into permanent data loss (what the reader saw as
        // "all saved posts are gone"). Only an explicit removal of the last post may
        // write an empty index (remove() clears `loadedCount` for that).
        if items.isEmpty, loadedCount > 0 { return }
        let snapshot = items
        let url = indexURL
        DiskWriter.queue.async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
