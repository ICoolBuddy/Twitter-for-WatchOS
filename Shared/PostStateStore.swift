import Foundation
import SwiftUI
import XKit
#if os(watchOS)
import WatchKit
#endif

/// Optimistic overlay for like / repost / bookmark state, shared by every view
/// that shows a post, so toggling in the detail view updates the timeline too.
@MainActor
final class PostStateStore: ObservableObject {
    struct State: Equatable {
        var liked: Bool
        var likeCount: Int
        var retweeted: Bool
        var retweetCount: Int
        var bookmarked: Bool
    }

    @Published private var overrides: [String: State] = [:]
    @Published var lastError: XError?
    /// Actions performed while offline, replayed when the connection is back.
    @Published private(set) var pendingCount = 0

    private var queue: [PendingAction] = []
    private var flushing = false

    private static let queueKey = "perchPendingActions"

    /// One like/repost/bookmark tap that still has to reach X.
    struct PendingAction: Codable, Equatable {
        enum Kind: String, Codable { case like, retweet, bookmark }
        var kind: Kind
        var tweetId: String
        var on: Bool
    }

    init() { loadQueue() }

    func state(for t: XTweet) -> State {
        overrides[t.id] ?? State(liked: t.liked, likeCount: t.likeCount, retweeted: t.retweeted,
                                 retweetCount: t.retweetCount, bookmarked: t.bookmarked)
    }

    func reset() { overrides.removeAll() }

    func toggleLike(_ t: XTweet, client: XClient) {
        var s = state(for: t)
        let old = s
        s.liked.toggle()
        s.likeCount = max(0, s.likeCount + (s.liked ? 1 : -1))
        let pending = PendingAction(kind: .like, tweetId: t.id, on: s.liked)
        perform(t, new: s, old: old, pending: pending) { try await client.setLiked(s.liked, tweetId: t.id) }
    }

    func toggleRetweet(_ t: XTweet, client: XClient) {
        var s = state(for: t)
        let old = s
        s.retweeted.toggle()
        s.retweetCount = max(0, s.retweetCount + (s.retweeted ? 1 : -1))
        let pending = PendingAction(kind: .retweet, tweetId: t.id, on: s.retweeted)
        perform(t, new: s, old: old, pending: pending) { try await client.setRetweeted(s.retweeted, tweetId: t.id) }
    }

    func toggleBookmark(_ t: XTweet, client: XClient) {
        var s = state(for: t)
        let old = s
        s.bookmarked.toggle()
        let pending = PendingAction(kind: .bookmark, tweetId: t.id, on: s.bookmarked)
        perform(t, new: s, old: old, pending: pending) { try await client.setBookmarked(s.bookmarked, tweetId: t.id) }
    }

    private func perform(_ t: XTweet, new: State, old: State,
                         pending: PendingAction? = nil,
                         _ op: @escaping () async throws -> Void) {
        overrides[t.id] = new
        Haptics.click()
        Task {
            do {
                try await op()
            } catch {
                let e = XError.from(error)
                lastError = e
                if let pending, e.isTransientWhileOffline {
                    // Offline or X is having a moment: keep the optimistic state
                    // and send it again as soon as the connection is back.
                    enqueue(pending)
                } else {
                    overrides[t.id] = old
                    Haptics.failure()
                }
            }
        }
    }

    // MARK: Offline queue

    /// Replays queued actions in order. Safe to call often (from every refresh,
    /// app foreground); it stops at the first failure and retries later.
    func flush(client: XClient) async {
        guard !queue.isEmpty, !flushing else { return }
        flushing = true
        defer { flushing = false }
        while let action = queue.first {
            do {
                switch action.kind {
                case .like: try await client.setLiked(action.on, tweetId: action.tweetId)
                case .retweet: try await client.setRetweeted(action.on, tweetId: action.tweetId)
                case .bookmark: try await client.setBookmarked(action.on, tweetId: action.tweetId)
                }
                queue.removeFirst()
                saveQueue()
            } catch {
                lastError = XError.from(error)
                return
            }
        }
    }

    private func enqueue(_ action: PendingAction) {
        queue.removeAll { $0.kind == action.kind && $0.tweetId == action.tweetId }
        queue.append(action)
        saveQueue()
    }

    private func loadQueue() {
        guard let data = UserDefaults.standard.data(forKey: Self.queueKey),
              let decoded = try? JSONDecoder().decode([PendingAction].self, from: data) else {
            pendingCount = 0
            return
        }
        queue = decoded
        pendingCount = decoded.count
    }

    private func saveQueue() {
        pendingCount = queue.count
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: Self.queueKey)
        }
    }
}

enum Haptics {
    static func click() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }
    static func success() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.success)
        #endif
    }
    static func failure() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.failure)
        #endif
    }
}

extension XError {
    /// Worth keeping the optimistic state and retrying: the request never got a
    /// real verdict from X.
    var isTransientWhileOffline: Bool {
        switch self {
        case .network, .server, .rateLimited:
            return true
        default:
            return false
        }
    }
}
