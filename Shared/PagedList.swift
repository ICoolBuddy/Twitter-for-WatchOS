import Foundation
import SwiftUI
import XKit

/// Cursor-paginated list loader used by every timeline-like screen.
@MainActor
final class PagedList<Item: Identifiable & Hashable>: ObservableObject {
    typealias Page = (items: [Item], cursor: String?, top: String?)

    /// What a list screen shows. Derived from the list's own state, so screens no longer
    /// recombine `isEmpty`/`isLoading`/`isRefreshing`/`error` each in their own way.
    enum Phase: Equatable {
        case idle          // nothing attempted yet
        case loading       // first page in flight, nothing to show
        case content       // items on screen
        case paging        // next page in flight (items on screen)
        case empty         // a page finished, nothing in it
        case failed(XError)
    }

    /// Start loading the next page when a row this close to the end appears.
    static var prefetchDistance: Int { 8 }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    /// True only while `refresh()` runs (not while loading further pages).
    @Published private(set) var isRefreshing = false
    @Published private(set) var reachedEnd = false
    @Published var error: XError?
    @Published private(set) var topCursor: String?
    /// When the last refresh succeeded (for an "updated 5m ago" line).
    @Published private(set) var lastUpdated: Date?
    /// True once a refresh for the current configuration finished (success or error);
    /// false after `reset()`. A cancelled refresh does not count, so the next
    /// appearance retries.
    @Published private(set) var hasLoadedFirstPage = false
    /// Paging stopped at the memory cap (`maxItems * 2`), not because X has no more.
    @Published private(set) var stoppedAtCap = false

    private var cursor: String?
    private var loadTask: Task<Void, Never>?
    private let maxItems: Int
    /// Bumped by every refresh and reset so late results from an older account
    /// or timeline kind are thrown away instead of overwriting the new list.
    private var generation = 0
    /// Which operation the current `error` came from, so Retry repeats *that*.
    private enum Failed { case refresh, more }
    private var lastFailure: Failed?
    var fetch: (String?) async throws -> Page
    /// Called with the first page after a successful refresh (for disk caching
    /// and for clearing the notification badge).
    var onFirstPage: (([Item], String?) -> Void)?
    /// Called with every page of items that becomes available — refresh, load
    /// more and the disk seed — so images can be prefetched.
    var onPage: (([Item]) -> Void)?
    /// Optional row filter (timeline filler); applied to every incoming page.
    var skip: ((Item) -> Bool)?
    /// Fetches the posts *newer* than a top cursor (home feeds: X's pull-to-refresh).
    /// When set, `refreshNewer()` uses it instead of reloading the first page.
    var topFetch: ((String) async throws -> Page)?
    /// Rows the reader already had on screen at some point. A merge never puts them
    /// back on top as if they were new.
    var alreadySeen: ((Item) -> Bool)?

    init(maxItems: Int = 300, fetch: @escaping (String?) async throws -> Page) {
        self.fetch = fetch
        self.maxItems = maxItems
    }

    var isEmpty: Bool { items.isEmpty }

    /// Any network work for this list (refresh or next page).
    var isFetching: Bool { isLoading || isRefreshing }

    var phase: Phase {
        if let error, items.isEmpty { return .failed(error) }
        if items.isEmpty { return hasLoadedFirstPage ? .empty : (isLoading ? .loading : .idle) }
        return (isLoading && !isRefreshing) ? .paging : .content
    }

    /// The end of the list is on screen: X has no more, or paging stopped at the cap.
    var showsEnd: Bool { reachedEnd && !items.isEmpty && !isLoading && error == nil }

    /// Shows cached rows before the first fetch. The same row filter as for network
    /// pages applies (any cache writer may have stored filler), and only the first
    /// screenful is warmed: the disk cache is deeper than the screen, and the network
    /// pages that follow warm the rest.
    func seed(_ cached: [Item]) {
        guard items.isEmpty else { return }
        let usable = cached.filter { skip?($0) != true }
        items = usable
        if !usable.isEmpty { onPage?(Array(usable.prefix(8))) }
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
        stoppedAtCap = false
        error = nil
        lastFailure = nil
        isLoading = false
        isRefreshing = false
        lastUpdated = nil
        hasLoadedFirstPage = false
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
                items = merged(items, with: fresh)
            } else {
                items = fresh
            }
            if !keepCursor {
                cursor = page.cursor
                reachedEnd = page.cursor == nil || page.items.isEmpty
                stoppedAtCap = false
            }
            topCursor = page.top
            lastUpdated = Date()
            lastFailure = nil
            hasLoadedFirstPage = true
            onFirstPage?(fresh, page.top)
            onPage?(fresh)
        } catch is CancellationError {
        } catch {
            let e = XError.from(error)
            if case .network(let m) = e, m == "Cancelled" { return }
            guard gen == generation else { return }
            lastFailure = .refresh
            self.error = e
            hasLoadedFirstPage = true
        }
    }

    /// X-style refresh: posts newer than the top of the list go above it; nothing on
    /// screen is removed or reordered, so after reading through the new posts the
    /// reader is back at the ones they had already seen. Falls back to a merging
    /// first-page refresh when there is no top cursor yet (a list seeded from disk).
    func refreshNewer() async {
        guard let top = topCursor, let topFetch, !items.isEmpty else {
            await refresh(merge: !items.isEmpty)
            return
        }
        loadTask?.cancel()
        generation += 1
        let gen = generation
        isLoading = true
        isRefreshing = true
        error = nil
        defer { if gen == generation { isLoading = false; isRefreshing = false } }
        do {
            let page = try await topFetch(top)
            try Task.checkCancellation()
            guard gen == generation else { return }
            let fresh = dedupe(page.items).filter { skip?($0) != true }
            items = merged(items, with: fresh)
            // The bottom cursor still belongs to the end of the list: untouched.
            topCursor = page.top ?? topCursor
            lastUpdated = Date()
            lastFailure = nil
            hasLoadedFirstPage = true
            onFirstPage?(Array(items.prefix(40)), topCursor)
            onPage?(fresh)
        } catch is CancellationError {
        } catch {
            let e = XError.from(error)
            if case .network(let m) = e, m == "Cancelled" { return }
            guard gen == generation else { return }
            lastFailure = .refresh
            self.error = e
            hasLoadedFirstPage = true
        }
    }

    /// Same identity = the fresh value replaces the old row in place (fresh data, same
    /// position); new rows go on top, except ones the reader has already seen
    /// (`alreadySeen`). One `@Published` write.
    private func merged(_ old: [Item], with fresh: [Item]) -> [Item] {
        var index: [Item.ID: Int] = [:]
        index.reserveCapacity(old.count)
        for (i, item) in old.enumerated() { index[item.id] = i }
        var result = old
        var added: [Item] = []
        for item in fresh {
            if let i = index[item.id] {
                result[i] = item
            } else if alreadySeen?(item) != true {
                added.append(item)
            }
        }
        if !added.isEmpty { result.insert(contentsOf: added, at: 0) }
        return result
    }

    /// Call from a row's `onAppear`; loads the next page when the row is near the end.
    func loadMoreIfNeeded(current item: Item) {
        guard !isLoading, !isRefreshing, !reachedEnd, error == nil else { return }
        // O(1): only the row at the prefetch threshold arms the next page. The old
        // firstIndex(where:) scanned up to 400 rows for every row that appeared.
        let trigger = items.count > Self.prefetchDistance
            ? items[items.count - Self.prefetchDistance].id
            : items.last?.id
        guard item.id == trigger else { return }
        if cursor == nil {
            // Rows seeded from the disk have no cursor of their own (e.g. "Refresh when
            // opening" is off): the first page is how paging starts, instead of a dead end.
            isLoading = true                       // claimed before the task runs
            Task { await refresh(merge: !items.isEmpty) }
            return
        }
        loadMore()
    }

    func loadMore() {
        guard !isLoading, !reachedEnd, let cursor else { return }
        isLoading = true
        // Sampled when the load is armed, not when the task body starts: a reset in
        // between must make this page stale.
        let gen = generation
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadMore(cursor: cursor, generation: gen)
        }
    }

    private func loadMore(cursor start: String, generation gen: Int) async {
        defer { if gen == generation { isLoading = false } }
        guard gen == generation else { return }
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
                var index: [Item.ID: Int] = [:]
                index.reserveCapacity(items.count)
                for (i, item) in items.enumerated() { index[item.id] = i }
                var current = items
                var fresh: [Item] = []
                for item in page.items where skip?(item) != true {
                    // A row we already show (e.g. a conversation that grew) is refreshed
                    // in place instead of being skipped as a duplicate.
                    if let i = index[item.id] { current[i] = item } else { fresh.append(item) }
                }
                current.append(contentsOf: fresh)
                items = current
                if !fresh.isEmpty { onPage?(fresh) }
                self.cursor = page.cursor
                topCursor = page.top ?? topCursor
                // Never drop rows above the viewport while paging: removing leading
                // items moves everything up and reads as the feed jumping. Instead stop
                // paging at twice the window (memory) and say so at the end of the list.
                if items.count >= maxItems * 2 { reachedEnd = true; stoppedAtCap = true; return }
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
            guard gen == generation else { return }
            lastFailure = .more
            self.error = e
        }
    }

    /// "Tap to retry": repeats the operation that failed (a failed refresh is refreshed
    /// again, not answered with an older page).
    func retryMore() {
        error = nil
        let retryRefresh = lastFailure == .refresh || cursor == nil || reachedEnd
        lastFailure = nil
        if retryRefresh { Task { await refresh(merge: !items.isEmpty) } } else { loadMore() }
    }

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

/// Which cached timeline a file holds. The one place that names cache files, so
/// clearing (logout, account removal) cannot miss a kind of file.
enum TimelineCacheScope: Hashable {
    case home(account: String, kind: HomeKind)
    case profile(userId: String)

    static let homePrefix = "perch-home-"
    static let profilePrefix = "perch-profile-"

    var fileName: String {
        switch self {
        case .home(let account, let kind): return "\(Self.homePrefix)\(account)-\(kind.rawValue).json"
        case .profile(let userId): return "\(Self.profilePrefix)\(userId).json"
        }
    }
}

/// Last timelines on disk so the app opens instantly (and offline).
enum TimelineDiskCache {
    private static var directory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    static func url(_ scope: TimelineCacheScope) -> URL? {
        directory?.appendingPathComponent(scope.fileName)
    }

    /// Never replaces a cache with an empty page: an empty or unreadable response must
    /// not destroy the offline feed.
    static func save(_ items: [TimelineItem], scope: TimelineCacheScope) {
        guard let url = url(scope), !items.isEmpty else { return }
        let page = TimelinePage(items: Array(items.prefix(40)))
        DiskWriter.queue.async {
            if let d = try? JSONEncoder().encode(page) { try? d.write(to: url, options: .atomic) }
            // Profile timelines are one file per visited user: keep the newest few.
            if case .profile = scope {
                DiskWriter.trim(url.deletingLastPathComponent(), prefix: TimelineCacheScope.profilePrefix, keep: 30)
            }
        }
    }

    static func load(_ scope: TimelineCacheScope) -> [TimelineItem] {
        guard let url = url(scope), let d = try? Data(contentsOf: url),
              let p = try? JSONDecoder().decode(TimelinePage.self, from: d) else { return [] }
        return p.items
    }

    /// `load` off the main thread (screens seed from it while they open).
    static func loadAsync(_ scope: TimelineCacheScope) async -> [TimelineItem] {
        await withCheckedContinuation { continuation in
            DiskWriter.queue.async { continuation.resume(returning: load(scope)) }
        }
    }

    /// Logout: every cached timeline (home timelines of every account, visited profiles).
    static func clearAll() {
        remove { $0.hasPrefix(TimelineCacheScope.homePrefix) || $0.hasPrefix(TimelineCacheScope.profilePrefix) }
    }

    /// An account was removed: its home timelines.
    static func clear(account: String) {
        remove { $0.hasPrefix("\(TimelineCacheScope.homePrefix)\(account)-") }
    }

    private static func remove(where match: @escaping (String) -> Bool) {
        guard let dir = directory else { return }
        DiskWriter.queue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for f in files where match(f.lastPathComponent) { try? fm.removeItem(at: f) }
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
