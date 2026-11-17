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
            if merge, !items.isEmpty {
                let known = Set(items.map(\.id))
                let added = fresh.filter { !known.contains($0.id) }
                if !added.isEmpty { items.insert(contentsOf: added, at: 0) }
            } else {
                items = fresh
            }
            cursor = page.cursor
            topCursor = page.top
            reachedEnd = page.cursor == nil || page.items.isEmpty
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

    private func loadMore(cursor: String) async {
        let gen = generation
        defer { if gen == generation { isLoading = false } }
        do {
            let page = try await fetch(cursor)
            try Task.checkCancellation()
            guard gen == generation else { return }
            let existing = Set(items.map(\.id))
            let fresh = page.items.filter { skip?($0) != true && !existing.contains($0.id) }
            items.append(contentsOf: fresh)
            if !fresh.isEmpty { onPage?(fresh) }
            self.cursor = page.cursor
            topCursor = page.top ?? topCursor
            // Stop when the cursor stops moving or a page brings nothing new.
            reachedEnd = page.cursor == nil || page.cursor == cursor || fresh.isEmpty
            // Never drop rows above the viewport while paging: removing leading
            // items moves everything up and reads as the feed jumping. Instead stop
            // paging at twice the window, which keeps memory bounded.
            if items.count >= maxItems * 2 { reachedEnd = true }
        } catch is CancellationError {
        } catch {
            if gen == generation { self.error = XError.from(error) }
        }
    }

    func update(_ transform: (inout [Item]) -> Void) { transform(&items) }

    func cancel() { loadTask?.cancel() }

    private func dedupe(_ xs: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return xs.filter { seen.insert($0.id).inserted }
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
        DispatchQueue.global(qos: .utility).async {
            if let d = try? JSONEncoder().encode(page) { try? d.write(to: url, options: .atomic) }
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
