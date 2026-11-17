import Foundation
import SwiftUI
import XKit

/// Cursor-paginated list loader used by every timeline-like screen.
@MainActor
final class PagedList<Item: Identifiable & Hashable>: ObservableObject {
    typealias Page = (items: [Item], cursor: String?, top: String?)

    @Published private(set) var items: [Item] = []
    @Published private(set) var isLoading = false
    @Published private(set) var reachedEnd = false
    @Published var error: XError?
    @Published private(set) var topCursor: String?

    private var cursor: String?
    private var loadTask: Task<Void, Never>?
    private let maxItems: Int
    var fetch: (String?) async throws -> Page
    /// Called with the first page after a successful refresh (for disk caching).
    var onFirstPage: (([Item], String?) -> Void)?

    init(maxItems: Int = 300, fetch: @escaping (String?) async throws -> Page) {
        self.fetch = fetch
        self.maxItems = maxItems
    }

    var isEmpty: Bool { items.isEmpty }

    func seed(_ cached: [Item]) {
        if items.isEmpty { items = cached }
    }

    func loadIfNeeded() async {
        if items.isEmpty || cursor == nil && !reachedEnd { await refresh() }
    }

    func refresh() async {
        loadTask?.cancel()
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let page = try await fetch(nil)
            try Task.checkCancellation()
            items = dedupe(page.items)
            cursor = page.cursor
            topCursor = page.top
            reachedEnd = page.cursor == nil || page.items.isEmpty
            onFirstPage?(items, page.top)
        } catch is CancellationError {
        } catch {
            let e = XError.from(error)
            if case .network(let m) = e, m == "Cancelled" { return }
            self.error = e
        }
    }

    /// Call from a row's `onAppear`; loads the next page when the row is near the end.
    func loadMoreIfNeeded(current item: Item) {
        guard !isLoading, !reachedEnd, error == nil, let cursor else { return }
        guard let idx = items.firstIndex(where: { $0.id == item.id }), idx >= items.count - 4 else { return }
        loadTask = Task { await loadMore(cursor: cursor) }
    }

    func loadMore() {
        guard !isLoading, !reachedEnd, let cursor else { return }
        loadTask = Task { await loadMore(cursor: cursor) }
    }

    private func loadMore(cursor: String) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await fetch(cursor)
            try Task.checkCancellation()
            let existing = Set(items.map(\.id))
            let fresh = page.items.filter { !existing.contains($0.id) }
            items.append(contentsOf: fresh)
            if items.count > maxItems { items.removeFirst(items.count - maxItems) }
            self.cursor = page.cursor
            // Stop when the cursor stops moving or a page brings nothing new.
            reachedEnd = page.cursor == nil || page.cursor == cursor || fresh.isEmpty
        } catch is CancellationError {
        } catch {
            self.error = XError.from(error)
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

    static func clear() {
        for n in ["home-forYou", "home-following"] { if let u = url(n) { try? FileManager.default.removeItem(at: u) } }
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
