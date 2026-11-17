import Foundation
import SwiftUI
import XKit

/// Cursor-paginated list loader used by every timeline-like screen.
@MainActor
final class PagedList<Item: Identifiable & Hashable>: ObservableObject {
    typealias Page = (items: [Item], cursor: String?, top: String?)

    /// Start loading the next page when a row this close to the end appears.
    static var prefetchDistance: Int { 8 }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    /// True only while `refresh()` runs (not while loading further pages).
    @Published private(set) var isRefreshing = false
    @Published private(set) var reachedEnd = false
    @Published var error: XError?
    @Published private(set) var topCursor: String?
    /// How many posts the last merge refresh put above the old ones (for a
    /// "new posts" pill). 0 after a normal refresh.
    @Published private(set) var lastMergeAdded = 0
    /// When the last refresh succeeded (for an "updated 5m ago" line).
    @Published private(set) var lastUpdated: Date?

    private var cursor: String?
    private var loadTask: Task<Void, Never>?
    private let maxItems: Int
    /// Bumped by every refresh and reset so late results from an older account
    /// or timeline kind are thrown away instead of overwriting the new list.
    private var generation = 0
    var fetch: (String?) async throws -> Page
    /// Called with the first page after a successful refresh (for disk caching
    /// and for clearing the notification badge).
    var onFirstPage: (([Item], String?) -> Void)?
    /// Called with every page of items that becomes available — refresh, load
    /// more and the disk seed — so images can be prefetched.
    var onPage: (([Item]) -> Void)?
    /// Optional row filter (timeline filler); applied to every incoming page.
    var skip: ((Item) -> Bool)?

    init(maxItems: Int = 300, fetch: @escaping (String?) async throws -> Page) {
        self.fetch = fetch
        self.maxItems = maxItems
    }

    var isEmpty: Bool { items.isEmpty }

    func seed(_ cached: [Item]) {
        if items.isEmpty {
            items = cached
            if !cached.isEmpty { onPage?(cached) }
        }
    }

    /// Clears everything, including the cursor. Used when the account or the
    /// timeline kind changes.
    func reset() {
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        items = []
        cursor = nil
        topCursor = nil
        reachedEnd = false
        error = nil
        isLoading = false
        isRefreshing = false
        lastMergeAdded = 0
        lastUpdated = nil
    }

    func loadIfNeeded() async {
        guard !isLoading, !isRefreshing else { return }
        if items.isEmpty || (cursor == nil && !reachedEnd) { await refresh() }
    }

    /// - Parameter merge: keep the posts already on screen (and their order) and
    ///   only add the ones above them. Used by the automatic refresh on open so
    ///   nothing is reordered or removed under a reader who already scrolled.
    func refresh(merge: Bool = false) async {
        loadTask?.cancel()
        generation += 1
        let gen = generation
        isLoading = true
        isRefreshing = true
        error = nil
        defer { if gen == generation { isLoading = false; isRefreshing = false } }
        do {
            let page = try await fetch(nil)
            try Task.checkCancellation()
            guard gen == generation else { return }
            let fresh = dedupe(page.items).filter { skip?($0) != true }
            // Merging over a list that already pages from its own cursor keeps
            // that cursor: the fresh page's bottom cursor points just below the
            // *new* posts, so paging from it would only return posts that are
            // already on screen (and used to end the infinite scroll).
            let keepCursor = merge && !items.isEmpty && cursor != nil
            if merge, !items.isEmpty {
                let known = Set(items.map(\.id))
                let added = fresh.filter { !known.contains($0.id) }
                if !added.isEmpty { items.insert(contentsOf: added, at: 0) }
                lastMergeAdded = added.count
            } else {
                items = fresh
                lastMergeAdded = 0
            }
            if !keepCursor {
                cursor = page.cursor
                reachedEnd = page.cursor == nil || page.items.isEmpty
            }
            topCursor = page.top
            lastUpdated = Date()
            onFirstPage?(fresh, page.top)
            onPage?(fresh)
        } catch is CancellationError {
        } catch {
            let e = XError.from(error)
            if case .network(let m) = e, m == "Cancelled" { return }
            if gen == generation { self.error = e }
        }
    }

    /// Call from a row's `onAppear`; loads the next page when the row is near the end.
    func loadMoreIfNeeded(current item: Item) {
        guard !isLoading, !reachedEnd, error == nil, cursor != nil else { return }
        guard let idx = items.firstIndex(where: { $0.id == item.id }),
              idx >= items.count - Self.prefetchDistance else { return }
        loadMore()
    }

    func loadMore() {
        guard !isLoading, !reachedEnd, let cursor else { return }
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadMore(cursor: cursor)
        }
    }

    private func loadMore(cursor start: String) async {
        let gen = generation
        defer { if gen == generation { isLoading = false } }
        var next = start
        // A page can be made only of posts we already show (after a merge, or
        // after a disk seed with no cursor of its own) or of filtered filler.
        // Follow the cursor a few more pages instead of declaring the end.
        var duplicatePages = 0
        do {
            while true {
                let page = try await fetch(next)
                try Task.checkCancellation()
                guard gen == generation else { return }
                let existing = Set(items.map(\.id))
                let fresh = page.items.filter { skip?($0) != true && !existing.contains($0.id) }
                items.append(contentsOf: fresh)
                if !fresh.isEmpty { onPage?(fresh) }
                self.cursor = page.cursor
                topCursor = page.top ?? topCursor
                // Never drop rows above the viewport while paging: removing leading
                // items moves everything up and reads as the feed jumping. Instead stop
                // paging at twice the window, which keeps memory bounded.
                if items.count >= maxItems * 2 { reachedEnd = true; return }
                guard let moved = page.cursor, moved != next, !page.items.isEmpty else {
                    reachedEnd = true
                    return
                }
                if !fresh.isEmpty { return }
                duplicatePages += 1
                if duplicatePages >= 4 { return }   // keep the cursor; scrolling retries
                next = moved
            }
        } catch is CancellationError {
        } catch {
            let e = XError.from(error)
            if case .network(let m) = e, m == "Cancelled" { return }
            if gen == generation { self.error = e }
        }
    }

    /// "Tap to retry" after a failed page: clears the error and loads on.
    func retryMore() {
        error = nil
        if cursor != nil, !reachedEnd { loadMore() } else { Task { await refresh(merge: !items.isEmpty) } }
    }

    func clearMergeCount() { lastMergeAdded = 0 }

    func update(_ transform: (inout [Item]) -> Void) { transform(&items) }

    func cancel() { loadTask?.cancel() }

    private func dedupe(_ xs: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return xs.filter { seen.insert($0.id).inserted }
    }
}

/// One serial queue for every small cache write, so an older snapshot can never
/// land on disk after a newer one (a concurrent queue allowed that).
enum DiskWriter {
    static let queue = DispatchQueue(label: "com.perch.disk-writer", qos: .utility)

    /// Deletes the oldest files whose names start with `prefix` in `dir` until at
    /// most `keep` remain. Call on `queue`.
    static func trim(_ dir: URL, prefix: String, keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let matching = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
        guard matching.count > keep else { return }
        let dated = matching.map { url -> (URL, Date) in
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (url, d ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(matching.count - keep) { try? fm.removeItem(at: url) }
    }
}

/// Last home timeline on disk so the app opens instantly (and offline).
enum TimelineDiskCache {
    static func url(_ name: String) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("perch-\(name).json")
    }

    static func save(_ items: [TimelineItem], name: String) {
        guard let url = url(name) else { return }
        let page = TimelinePage(items: Array(items.prefix(40)))
        DiskWriter.queue.async {
            if let d = try? JSONEncoder().encode(page) { try? d.write(to: url, options: .atomic) }
            // Profile timelines are one file per visited user: keep the newest few.
            if name.hasPrefix("profile-") {
                DiskWriter.trim(url.deletingLastPathComponent(), prefix: "perch-profile-", keep: 30)
            }
        }
    }

    static func load(name: String) -> [TimelineItem] {
        guard let url = url(name), let d = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(TimelinePage.self, from: d) else { return [] }
        return p.items
    }

    /// Removes every cached home timeline (`perch-home-*`), for every account.
    static func clear() {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.lastPathComponent.hasPrefix("perch-home-") {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

extension TimelineItem {
    /// Empty rows (tombstones, ad shells, prompts) are not worth a place in a
    /// feed: no text, no media, nothing quoted.
    var isFiller: Bool {
        switch self {
        case .tweet(let t):
            let shown = t.displayed
            return shown.text.isEmpty && shown.media.isEmpty && shown.quotedTweet == nil
        case .conversation(let tweets):
            return tweets.allSatisfy { $0.text.isEmpty && $0.media.isEmpty }
        case .user:
            return false
        }
    }
}

/// Every tweet that will be displayed for these timeline items, quoted posts
/// included, de-duplicated by id. Used to warm the image cache after each page.
extension Array where Element == TimelineItem {
    var displayTweets: [XTweet] {
        var out: [XTweet] = []
        var seen = Set<String>()
        for tweet in flatMap(\.tweets) {
            let shown = tweet.displayed
            for t in [shown, shown.quotedTweet?.value].compactMap({ $0 }) {
                if seen.insert(t.id).inserted { out.append(t) }
            }
        }
        return out
    }
}

extension Int {
    /// 1234 → "1.2K", 1_500_000 → "1.5M".
    var compact: String {
        switch self {
        case ..<1000: return "\(self)"
        case ..<10_000: return String(format: "%.1fK", Double(self) / 1000).replacingOccurrences(of: ".0K", with: "K")
        case ..<1_000_000: return "\(self / 1000)K"
        default: return String(format: "%.1fM", Double(self) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }
}
