import Foundation
import ImageIO
import SwiftUI
import CoreGraphics
import XKit

/// Memory-conscious image loading: downloads with a plain URLSession (no cookies),
/// decodes with ImageIO downsampling to the display size, caches decoded CGImages in
/// an NSCache with a byte budget, and keeps the downloaded bytes in a small LRU disk
/// cache so the next launch shows images instantly (and background refresh can warm it).
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache = NSCache<NSString, CGImageBox>()
    private let session: URLSession
    /// `Caches/perch-img` — downloaded bytes keyed by a hash of the URL (see `fileStem`).
    private let diskDir: URL?
    /// Serial queue for all disk work. `lastTrim` is only read/written on it.
    private let ioQueue = DispatchQueue(label: "com.perch.imageloader.disk", qos: .utility)
    private var lastTrim = Date.distantPast

    final class CGImageBox {
        let image: CGImage
        init(_ i: CGImage) { image = i }
    }

    #if os(watchOS)
    private static let diskLimit = 60 * 1024 * 1024
    #else
    private static let diskLimit = 150 * 1024 * 1024
    #endif

    private init() {
        #if os(watchOS)
        cache.totalCostLimit = 12 * 1024 * 1024
        cache.countLimit = 60
        #else
        cache.totalCostLimit = 60 * 1024 * 1024
        cache.countLimit = 300
        #endif
        let cfg = URLSessionConfiguration.default
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        // Bytes live in our own LRU disk cache; keep URLCache memory-only so the same
        // image is not stored twice.
        cfg.urlCache = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 0)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("perch-img", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        diskDir = dir
    }

    // MARK: - Loading

    func cached(_ url: URL, maxPixel: Int) -> CGImage? {
        cache.object(forKey: key(url, maxPixel))?.image
    }

    /// Returns the decoded image: memory cache, then disk cache, then the network
    /// (downloaded bytes are written to the disk cache before decoding).
    func load(_ url: URL, maxPixel: Int) async throws -> CGImage {
        let k = key(url, maxPixel)
        if let c = cache.object(forKey: k) { return c.image }
        var data = await diskData(for: url)
        if data == nil {
            let (downloaded, _) = try await session.data(from: url)
            data = downloaded
            await storeOnDisk(downloaded, for: url)
        }
        try Task.checkCancellation()
        guard let bytes = data, let img = Self.downsample(bytes, maxPixel: maxPixel) else {
            throw URLError(.cannotDecodeContentData)
        }
        cache.setObject(CGImageBox(img), forKey: k, cost: img.bytesPerRow * img.height)
        return img
    }

    /// Fire-and-forget, low priority warm-up used by background refresh: downloads the
    /// bytes into the disk cache and decodes them so the feed renders instantly when the
    /// app is opened. Deliberately not `async`, so no caller has to await it; callers that
    /// want to spend their background budget on it can `await` the returned task's `value`.
    @discardableResult
    func prefetch(_ urls: [URL], maxPixel: Int) -> Task<Void, Never> {
        let list = Self.unique(urls)
        return Task.detached(priority: .utility) { [self] in
            for url in list {
                if Task.isCancelled { return }
                if self.cache.object(forKey: self.key(url, maxPixel)) != nil { continue }
                _ = try? await self.load(url, maxPixel: maxPixel)
            }
        }
    }

    func purge() { cache.removeAllObjects() }

    private func key(_ url: URL, _ px: Int) -> NSString { "\(px)|\(url.absoluteString)" as NSString }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for url in urls where seen.insert(url.absoluteString).inserted {
            out.append(url)
        }
        return out
    }

    // MARK: - Disk cache (Caches/perch-img, LRU by modification date)

    private func diskFile(for url: URL) -> URL? {
        guard let diskDir else { return nil }
        return diskDir.appendingPathComponent(Self.fileStem(url)).appendingPathExtension("img")
    }

    /// FNV-1a 64 of the URL string: short, stable, filesystem-safe file name.
    private static func fileStem(_ url: URL) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in url.absoluteString.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private func diskData(for url: URL) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            ioQueue.async { cont.resume(returning: self.readDisk(url)) }
        }
    }

    private func storeOnDisk(_ data: Data, for url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                self.writeDisk(data, for: url)
                cont.resume()
            }
        }
    }

    /// Runs on `ioQueue`.
    private func readDisk(_ url: URL) -> Data? {
        guard let file = diskFile(for: url) else { return nil }
        guard let data = try? Data(contentsOf: file) else { return nil }
        // LRU: bump the modification date on every hit.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }

    /// Runs on `ioQueue`.
    private func writeDisk(_ data: Data, for url: URL) {
        guard !data.isEmpty, let file = diskFile(for: url) else { return }
        try? data.write(to: file, options: .atomic)
        trimDiskIfNeeded()
    }

    /// Runs on `ioQueue`. Throttled eviction: when the folder grows past the budget,
    /// delete the oldest files down to 75 % of it.
    private func trimDiskIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastTrim) > 30 else { return }
        lastTrim = now
        guard let diskDir else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: diskDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = []
        var total = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = values?.fileSize ?? 0
            total += size
            entries.append((url: file, date: values?.contentModificationDate ?? Date.distantPast, size: size))
        }
        guard total > Self.diskLimit else { return }
        entries.sort { $0.date < $1.date }
        var remaining = total
        for entry in entries {
            if remaining <= Self.diskLimit * 3 / 4 { break }
            try? FileManager.default.removeItem(at: entry.url)
            remaining -= entry.size
        }
    }

    // MARK: - Decoding

    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
    }
}

/// `AsyncImage` replacement backed by `ImageLoader`. `placeholderURL` (X's tiny preview)
/// is shown, blurred, until `url` has finished loading.
struct RemoteImage: View {
    let url: URL?
    var placeholderURL: URL? = nil
    var maxPixel: Int = 300
    var contentMode: ContentMode = .fill

    @State private var image: CGImage?
    @State private var placeholder: CGImage?
    @State private var failed = false

    private static let placeholderPixels = 200

    var body: some View {
        ZStack {
            if let image {
                picture(image)
            } else if let placeholder {
                picture(placeholder)
                    .blur(radius: 8)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.25))
                    .overlay {
                        if failed { Image(systemName: "photo").foregroundStyle(.secondary) }
                    }
            }
        }
        .clipped()
        .task(id: url) { await loadFull() }
        .task(id: placeholderURL) { await loadPlaceholder() }
    }

    private func picture(_ cg: CGImage) -> some View {
        Image(decorative: cg, scale: 1)
            .resizable()
            .aspectRatio(contentMode: contentMode)
    }

    private func loadFull() async {
        failed = false
        image = nil
        guard let url else { return }
        if let c = ImageLoader.shared.cached(url, maxPixel: maxPixel) {
            image = c
            return
        }
        do {
            image = try await ImageLoader.shared.load(url, maxPixel: maxPixel)
        } catch {
            if !(error is CancellationError) && !Task.isCancelled { failed = true }
        }
    }

    private func loadPlaceholder() async {
        placeholder = nil
        guard let placeholderURL else { return }
        if let c = ImageLoader.shared.cached(placeholderURL, maxPixel: Self.placeholderPixels) {
            placeholder = c
            return
        }
        placeholder = try? await ImageLoader.shared.load(placeholderURL, maxPixel: Self.placeholderPixels)
    }
}

struct Avatar: View {
    let user: XUser
    var size: CGFloat = 24

    var body: some View {
        RemoteImage(url: size > 40 ? user.avatarLargeURL : user.avatarURL, maxPixel: Int(size * 2.5))
            .frame(width: size, height: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}
