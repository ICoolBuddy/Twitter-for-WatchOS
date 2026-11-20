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

    /// URLs that will never decode (4xx / bad bytes). Remembered for the session so a
    /// dead row cannot re-download on every appearance, and prefetch skips them too.
    private let failedLock = NSLock()
    private var permanentFailures: Set<String> = []

    private func isPermanentFailure(_ url: URL) -> Bool {
        failedLock.withLock { permanentFailures.contains(url.absoluteString) }
    }

    private func markPermanentFailure(_ url: URL) {
        failedLock.withLock {
            if permanentFailures.count > 600 { permanentFailures.removeAll() }
            permanentFailures.insert(url.absoluteString)
        }
    }

    private let cache = NSCache<NSString, CGImageBox>()
    private let session: URLSession
    /// `Caches/perch-img` — downloaded bytes keyed by a hash of the URL (see `fileStem`).
    private let diskDir: URL?
    /// Serial queue for all disk work. `lastTrim` is only read/written on it.
    private let ioQueue = DispatchQueue(label: "com.perch.imageloader.disk", qos: .utility)
    private var lastTrim = Date.distantPast
    /// Downloads in flight, keyed like the memory cache.
    private let inflightLock = NSLock()
    private var inflight: [String: Task<CGImage, Error>] = [:]

    final class CGImageBox {
        let image: CGImage
        init(_ i: CGImage) { image = i }
    }

    #if os(watchOS)
    private static let diskLimit = 60 * 1024 * 1024
    #else
    private static let diskLimit = 150 * 1024 * 1024
    #endif

    /// Background prefetch never runs more than three downloads at a time, across
    /// all `prefetch` / `prefetchFeed` calls.
    private static let prefetchGate = PrefetchGate(limit: 3)

    private init() {
        #if os(watchOS)
        cache.totalCostLimit = 24 * 1024 * 1024
        cache.countLimit = 150
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
        // Saved (offline) media: decode straight from the local file.
        if url.isFileURL {
            guard let bytes = try? Data(contentsOf: url),
                  let image = Self.downsample(bytes, maxPixel: maxPixel) else {
                throw URLError(.fileDoesNotExist)
            }
            cache.setObject(CGImageBox(image), forKey: k, cost: image.bytesPerRow * image.height)
            return image
        }
        // One download per image: the visible row and the prefetcher (or two rows
        // showing the same avatar) share a single request.
        let task: Task<CGImage, Error> = inflightLock.withLock {
            if let running = inflight[k as String] { return running }
            let created = Task<CGImage, Error> { try await self.fetchAndDecode(url, maxPixel: maxPixel, key: k) }
            inflight[k as String] = created
            return created
        }
        defer { inflightLock.withLock { inflight[k as String] = nil } }
        return try await task.value
    }

    private func fetchAndDecode(_ url: URL, maxPixel: Int, key k: NSString) async throws -> CGImage {
        if isPermanentFailure(url) { throw URLError(.badServerResponse) }
        if let bytes = await diskData(for: url) {
            if let img = Self.downsample(bytes, maxPixel: maxPixel) {
                cache.setObject(CGImageBox(img), forKey: k, cost: img.bytesPerRow * img.height)
                return img
            }
            // A bad file (older builds stored error pages): drop it and download again.
            await removeFromDisk(url)
        }
        let startedAt = Date()
        let (downloaded, response) = try await session.data(from: url)
        // Images are most of the traffic: let the link-speed estimate see them.
        TransferMonitor.shared.record(bytes: downloaded.count, over: Date().timeIntervalSince(startedAt))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if (400..<500).contains(http.statusCode) { markPermanentFailure(url) }
            throw URLError(.badServerResponse)
        }
        guard let img = Self.downsample(downloaded, maxPixel: maxPixel) else {
            markPermanentFailure(url)
            throw URLError(.cannotDecodeContentData)
        }
        // Only bytes that really decode go to the disk cache; anything else would
        // fail forever (and make the prefetcher skip the URL).
        await storeOnDisk(downloaded, for: url)
        cache.setObject(CGImageBox(img), forKey: k, cost: img.bytesPerRow * img.height)
        return img
    }

    /// Fire-and-forget, low priority warm-up used by background refresh: downloads the
    /// bytes into the disk cache and decodes them so the feed renders instantly when the
    /// app is opened. At most three downloads run at a time; URLs that are already in
    /// memory or on disk are skipped. Not `async`, so no caller has to await it; callers
    /// that want to spend their background budget on it can `await` the returned task.
    @discardableResult
    func prefetch(_ urls: [URL], maxPixel: Int) -> Task<Void, Never> {
        prefetchItems(urls.map { (url: $0, maxPixel: maxPixel) })
    }

    /// Warms the exact images a feed page is about to display, so prefetch and display
    /// share cache keys: each post's author avatar, the first media's tiny preview and
    /// the full feed image (see `feedImage(for:)`).
    @discardableResult
    func prefetchFeed(_ tweets: [XTweet]) -> Task<Void, Never> {
        var items: [(url: URL, maxPixel: Int)] = []
        var seen = Set<String>()
        func add(_ url: URL?, _ maxPixel: Int) {
            guard let url else { return }
            guard seen.insert("\(maxPixel)|\(url.absoluteString)").inserted else { return }
            items.append((url: url, maxPixel: maxPixel))
        }
        // Adaptive: on a slow (Bluetooth-relayed) link or before anything was measured
        // only warm the few posts about to be visible; on a fast one the whole page.
        for tweet in tweets.prefix(LinkBudget.prefetchPostCount) {
            let t = tweet.displayed
            // `Avatar` shows the `_bigger` variant at feed size (44 pt): warm only
            // that one (warming the `_normal` one too doubled avatar traffic).
            add(t.author.avatarLargeURL ?? t.author.avatarURL, Int(44 * 2.5))
            let media = t.media
            if media.count >= 2, media.allSatisfy({ $0.type == .photo }) {
                // Grid tiles (FeedPostView.gridTile).
                for m in media.prefix(4) {
                    add(m.previewURL, 200)
                    add(m.feedURL, 300)
                }
            } else if let first = media.first {
                add(first.previewURL, 200)
                let feed = Self.feedImage(for: first)
                add(feed.url, feed.maxPixel)
            }
        }
        return prefetchItems(items)
    }

    /// The URL and decode size the feed uses for one media item. Aspect ratios below
    /// 0.9 (screenshots) use the 1200 px "medium" image decoded tall enough to stay
    /// sharp at full width; everything else uses the 680 px "small" one at 450 px.
    static func feedImage(for media: XMedia) -> (url: URL, maxPixel: Int) {
        let ratio = media.aspectRatio
        if ratio < 0.9 {
            return (media.fullURL, min(1400, Int(450 / max(ratio, 0.3))))
        }
        return (media.feedURL, 450)
    }

    @discardableResult
    private func prefetchItems(_ items: [(url: URL, maxPixel: Int)]) -> Task<Void, Never> {
        Task.detached(priority: .utility) { [self] in
            await withTaskGroup(of: Void.self) { group in
                for item in items {
                    group.addTask { [self] in
                        if Task.isCancelled { return }
                        if self.cache.object(forKey: self.key(item.url, item.maxPixel)) != nil { return }
                        if self.hasDiskData(for: item.url) { return }
                        await Self.prefetchGate.acquire()
                        if Task.isCancelled {
                            await Self.prefetchGate.release()
                            return
                        }
                        _ = try? await self.load(item.url, maxPixel: item.maxPixel)
                        await Self.prefetchGate.release()
                    }
                }
            }
        }
    }

    func purge() { cache.removeAllObjects() }


    private func key(_ url: URL, _ px: Int) -> NSString { "\(px)|\(url.absoluteString)" as NSString }

    /// Cheap synchronous check used by prefetch to avoid downloading bytes that are
    /// already cached. Callable from any thread (the disk folder is immutable).
    private func hasDiskData(for url: URL) -> Bool {
        guard let file = diskFile(for: url) else { return false }
        return FileManager.default.fileExists(atPath: file.path)
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

    private func removeFromDisk(_ url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                if let file = self.diskFile(for: url) { try? FileManager.default.removeItem(at: file) }
                cont.resume()
            }
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

/// Caps concurrent background downloads. Requests that arrive while the slots are
/// full park on a continuation and are resumed in FIFO order.
private actor PrefetchGate {
    private let limit: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            active = max(0, active - 1)
        } else {
            // Hand this slot straight to the next waiter; `active` stays unchanged.
            let next = waiters.removeFirst()
            next.resume()
        }
    }
}

/// `AsyncImage` replacement backed by `ImageLoader`. `placeholderURL` (X's tiny preview)
/// is shown, blurred, until `url` has finished loading. The memory cache is read
/// synchronously in `init`, so an already-decoded image is on screen in the first frame.
struct RemoteImage: View {
    let url: URL?
    var placeholderURL: URL? = nil
    var maxPixel: Int = 300
    var contentMode: ContentMode = .fill
    /// Lower-quality copy of the same picture, already decoded from the feed cache.
    /// Shown in the first frame and kept until the full image arrives.
    var fallbackURL: URL? = nil
    var fallbackMaxPixel: Int = 300

    @State private var image: CGImage?
    @State private var placeholder: CGImage?
    @State private var failed = false

    private static let placeholderPixels = 200

    init(url: URL?, placeholderURL: URL? = nil, maxPixel: Int = 300, contentMode: ContentMode = .fill,
         fallbackURL: URL? = nil, fallbackMaxPixel: Int = 300) {
        self.url = url
        self.placeholderURL = placeholderURL
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.fallbackURL = fallbackURL
        self.fallbackMaxPixel = fallbackMaxPixel
        _image = State(initialValue: Self.cached(url, maxPixel) ?? Self.cached(fallbackURL, fallbackMaxPixel))
        _placeholder = State(initialValue: placeholderURL.flatMap {
            ImageLoader.shared.cached($0, maxPixel: RemoteImage.placeholderPixels)
        })
    }

    private static func cached(_ url: URL?, _ maxPixel: Int) -> CGImage? {
        guard let url else { return nil }
        return ImageLoader.shared.cached(url, maxPixel: maxPixel)
    }

    var body: some View {
        ZStack {
            if let image {
                picture(image)
            } else if let placeholder {
                picture(placeholder)
                    .blur(radius: 8)
            } else {
                Skeleton(corner: 0)
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
        guard let url else {
            image = nil
            return
        }
        // The view starts with a cached image (see `init`: the full one, or the
        // feed-sized fallback); never blank it, only replace it when the full
        // image has arrived.
        if let c = ImageLoader.shared.cached(url, maxPixel: maxPixel) {
            image = c
            return
        }
        if image == nil, let fallbackURL {
            image = ImageLoader.shared.cached(fallbackURL, maxPixel: fallbackMaxPixel)
        }
        // The task only restarts when the URL changes, so a download that failed once
        // used to stay broken for as long as the row stayed on screen: retry, backing off.
        for attempt in 0..<3 {
            do {
                image = try await ImageLoader.shared.load(url, maxPixel: maxPixel)
                return
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                // A 4xx or undecodable body will not get better: no retries (the loader
                // remembers it too). Only a flaky link is worth three attempts.
                if let u = error as? URLError,
                   ![.timedOut, .networkConnectionLost, .notConnectedToInternet,
                     .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(u.code) {
                    failed = true
                    return
                }
                if attempt == 2 { failed = true; return }
                try? await Task.sleep(nanoseconds: 700_000_000 << UInt64(attempt))
                if Task.isCancelled { return }
            }
        }
    }

    private func loadPlaceholder() async {
        guard let placeholderURL else {
            placeholder = nil
            return
        }
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
