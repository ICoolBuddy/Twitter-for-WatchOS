import Foundation
import Combine

/// Downloads the smallest MP4 for a post's video/GIF into `Caches/perch-video`.
///
/// Streaming an AVPlayer directly on the Watch gives no usable progress (and is
/// unreliable over Bluetooth), so the media viewer downloads the file first with
/// `URLSession.bytes(for:)`, shows progress, then plays the local file.
@MainActor
final class VideoDownloader: ObservableObject {
    /// 0…1. Stays at 0 while the server has not told us the total size.
    @Published private(set) var progress: Double = 0
    @Published private(set) var bytesPerSecond: Double = 0
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var totalBytes: Int64?
    /// Set once the whole file is on disk; the caller can then create an `AVPlayer`.
    @Published private(set) var fileURL: URL?
    @Published private(set) var error: String?

    /// How often published values may change while downloading.
    private static let publishInterval: TimeInterval = 0.25
    private static let chunkSize = 16384

    private var task: Task<Void, Never>?
    private var remoteURL: URL?
    private var generation = 0
    private var lastPublish = Date.distantPast
    private var lastPublishedBytes: Int64 = 0

    /// Starts (or resumes from the cache) the download for `url`. Calling it again
    /// with the same URL while the file is downloading or complete does nothing.
    func start(_ url: URL) {
        if remoteURL == url, task != nil || fileURL != nil { return }
        cancel()
        remoteURL = url
        error = nil
        fileURL = nil
        progress = 0
        bytesPerSecond = 0
        receivedBytes = 0
        totalBytes = nil

        if let cached = Self.completedFile(for: url) {
            let size = Self.fileSize(cached)
            fileURL = cached
            progress = 1
            receivedBytes = size
            totalBytes = size
            return
        }

        lastPublish = .distantPast
        lastPublishedBytes = 0
        generation += 1
        let attempt = generation
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(url, attempt: attempt)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        bytesPerSecond = 0
    }

    // MARK: - Download

    private func run(_ url: URL, attempt: Int) async {
        defer {
            // A cancelled attempt must not clear the handle of the attempt that
            // replaced it.
            if generation == attempt {
                task = nil
                bytesPerSecond = 0
            }
        }
        guard let directory = Self.directory(),
              let finalURL = Self.finalFileURL(for: url) else {
            error = "No cache folder."
            return
        }
        // A unique part name per attempt: a late cancellation cannot delete the
        // partial file of the attempt that replaced it.
        let partURL = directory
            .appendingPathComponent(Self.fileStem(url) + "-" + UUID().uuidString)
            .appendingPathExtension("part")

        do {
            let cfg = URLSessionConfiguration.default
            cfg.httpShouldSetCookies = false
            cfg.httpCookieAcceptPolicy = .never
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.urlCache = nil
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 300
            let session = URLSession(configuration: cfg)
            defer { session.finishTasksAndInvalidate() }

            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30

            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            if http.expectedContentLength > 0 {
                totalBytes = http.expectedContentLength
            }

            try? FileManager.default.removeItem(at: partURL)
            guard FileManager.default.createFile(atPath: partURL.path, contents: nil) else {
                throw URLError(.cannotCreateFile)
            }
            let handle = try FileHandle(forWritingTo: partURL)
            var buffer = Data()
            buffer.reserveCapacity(Self.chunkSize)
            var received: Int64 = 0
            do {
                for try await byte in bytes {
                    try Task.checkCancellation()
                    buffer.append(byte)
                    received += 1
                    if buffer.count >= Self.chunkSize {
                        try handle.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                        publish(received)
                    }
                }
                if !buffer.isEmpty {
                    try handle.write(contentsOf: buffer)
                }
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try Task.checkCancellation()
            publish(received, force: true)

            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: partURL, to: finalURL)
            receivedBytes = received
            totalBytes = max(totalBytes ?? received, received)
            progress = 1
            fileURL = finalURL
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: partURL)
        } catch {
            try? FileManager.default.removeItem(at: partURL)
            if !Task.isCancelled {
                self.error = error.localizedDescription
            }
        }
    }

    /// Publishes received bytes, progress and speed at most four times a second.
    private func publish(_ received: Int64, force: Bool = false) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastPublish)
        guard force || elapsed >= Self.publishInterval else { return }
        if lastPublish != Date.distantPast, elapsed > 0.05 {
            let instantaneous = Double(received - lastPublishedBytes) / elapsed
            bytesPerSecond = bytesPerSecond > 0
                ? bytesPerSecond * 0.6 + instantaneous * 0.4
                : instantaneous
        }
        receivedBytes = received
        if let total = totalBytes, total > 0 {
            progress = min(0.999, Double(received) / Double(total))
        }
        lastPublish = now
        lastPublishedBytes = received
    }

    // MARK: - Files (Caches/perch-video/<hash>.mp4)

    private static func directory() -> URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("perch-video", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func finalFileURL(for url: URL) -> URL? {
        directory()?.appendingPathComponent(fileStem(url)).appendingPathExtension("mp4")
    }

    /// A file in the cache only counts as complete once it was moved from `.part`.
    private static func completedFile(for url: URL) -> URL? {
        guard let file = finalFileURL(for: url), fileSize(file) > 0 else { return nil }
        return file
    }

    private static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    /// FNV-1a 64 of the URL: short, stable, filesystem-safe file name.
    private static func fileStem(_ url: URL) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }
}
