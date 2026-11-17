import Foundation
import SwiftUI
import XKit
#if os(watchOS)
import WatchKit
#endif

/// Optimistic overlay for like / repost / bookmark state, shared by every view
/// that shows a post, so toggling in the detail view updates the timeline too.
///
/// Every (action, post) pair is driven by one worker at a time that sends the
/// *latest* wanted state, so fast double taps can neither race nor reach X in
/// the wrong order. Offline taps are queued per account and replayed later; an
/// online success for the same post removes its queued entry, so a stale queued
/// tap can never undo a newer one.
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
    /// Actions of the active account performed while offline, replayed when the
    /// connection is back.
    @Published private(set) var pendingCount = 0

    private var queue: [PendingAction] = []
    private var flushing = false
    /// The account taps are made as (set by `AppModel`).
    private(set) var accountId: String?

    private static let queueKey = "perchPendingActions"

    /// One like/repost/bookmark tap that still has to reach X.
    struct PendingAction: Codable, Equatable {
        enum Kind: String, Codable { case like, retweet, bookmark }
        var kind: Kind
        var tweetId: String
        var on: Bool
        /// Older builds did not store it; those entries count as the active account.
        var accountId: String?
    }

    private struct Key: Hashable {
        let kind: PendingAction.Kind
        let tweetId: String
    }

    /// What the reader wants for a post, while a worker is sending it.
    private var desired: [Key: Bool] = [:]
    /// What X is known to have (from the post when first tapped, then from
    /// successful requests). Used to revert after a permanent failure.
    private var confirmed: [Key: Bool] = [:]
    private var running: Set<Key> = []

    init() { loadQueue() }

    /// The optimistic state, unless the post object already carries the same
    /// flags (fresh data from X): then its newer counts are shown.
    func state(for t: XTweet) -> State {
        let server = State(liked: t.liked, likeCount: t.likeCount, retweeted: t.retweeted,
                           retweetCount: t.retweetCount, bookmarked: t.bookmarked)
        guard let o = overrides[t.id] else { return server }
        if o.liked == server.liked, o.retweeted == server.retweeted, o.bookmarked == server.bookmarked {
            return server
        }
        return o
    }

    /// Clears the optimistic state (account switch / logout). The queue is kept
    /// per account; see `setAccount` and `clearQueue`.
    func reset() {
        overrides.removeAll()
        desired.removeAll()
        confirmed.removeAll()
    }

    func setAccount(_ id: String?) {
        guard id != accountId else { return }
        accountId = id
        reset()
        updatePendingCount()
    }

    /// Logout: nothing queued may be sent later as anyone.
    func clearQueue() {
        queue.removeAll()
        saveQueue()
    }

    /// A removed account's queued taps are dropped.
    func dropQueue(accountId id: String) {
        queue.removeAll { $0.accountId == id }
        saveQueue()
    }

    func toggleLike(_ t: XTweet, client: XClient) {
        var s = state(for: t)
        let key = Key(kind: .like, tweetId: t.id)
        if confirmed[key] == nil { confirmed[key] = t.liked }
        s.liked.toggle()
        s.likeCount = max(0, s.likeCount + (s.liked ? 1 : -1))
        apply(s, to: t.id)
        request(key, on: s.liked, client: client)
    }

    func toggleRetweet(_ t: XTweet, client: XClient) {
        var s = state(for: t)
        let key = Key(kind: .retweet, tweetId: t.id)
        if confirmed[key] == nil { confirmed[key] = t.retweeted }
        s.retweeted.toggle()
        s.retweetCount = max(0, s.retweetCount + (s.retweeted ? 1 : -1))
        apply(s, to: t.id)
        request(key, on: s.retweeted, client: client)
    }

    func toggleBookmark(_ t: XTweet, client: XClient) {
        var s = state(for: t)
        let key = Key(kind: .bookmark, tweetId: t.id)
        if confirmed[key] == nil { confirmed[key] = t.bookmarked }
        s.bookmarked.toggle()
        apply(s, to: t.id)
        request(key, on: s.bookmarked, client: client)
    }

    private func apply(_ s: State, to id: String) {
        overrides[id] = s
        Haptics.click()
    }

    private func request(_ key: Key, on: Bool, client: XClient) {
        desired[key] = on
        guard !running.contains(key) else { return }   // the running worker picks it up
        running.insert(key)
        let account = accountId
        Task { await drive(key, client: client, account: account) }
    }

    /// Sends the latest wanted state until X agrees with it.
    private func drive(_ key: Key, client: XClient, account: String?) async {
        defer { running.remove(key) }
        while let want = desired[key] {
            if want == confirmed[key] {
                desired[key] = nil
                // Toggled back before anything was sent: nothing queued may linger.
                removeQueued(key, account: account)
                return
            }
            do {
                try await send(key.kind, on: want, tweetId: key.tweetId, client: client)
                guard account == accountId else { return }   // account switched meanwhile
                confirmed[key] = want
                removeQueued(key, account: account)
                if desired[key] == want { desired[key] = nil }
            } catch {
                guard account == accountId else { return }
                let e = XError.from(error)
                lastError = e
                desired[key] = nil
                if e.isTransientWhileOffline {
                    // Offline or X is having a moment: keep the optimistic state and
                    // send it again as soon as the connection is back.
                    enqueue(PendingAction(kind: key.kind, tweetId: key.tweetId, on: want, accountId: account))
                } else {
                    if let c = confirmed[key] { revert(key, to: c) }
                    Haptics.failure()
                }
                return
            }
        }
    }

    private func send(_ kind: PendingAction.Kind, on: Bool, tweetId: String, client: XClient) async throws {
        switch kind {
        case .like: try await client.setLiked(on, tweetId: tweetId)
        case .retweet: try await client.setRetweeted(on, tweetId: tweetId)
        case .bookmark: try await client.setBookmarked(on, tweetId: tweetId)
        }
    }

    private func revert(_ key: Key, to value: Bool) {
        guard var s = overrides[key.tweetId] else { return }
        switch key.kind {
        case .like:
            if s.liked != value { s.liked = value; s.likeCount = max(0, s.likeCount + (value ? 1 : -1)) }
        case .retweet:
            if s.retweeted != value { s.retweeted = value; s.retweetCount = max(0, s.retweetCount + (value ? 1 : -1)) }
        case .bookmark:
            s.bookmarked = value
        }
        overrides[key.tweetId] = s
    }

    // MARK: Offline queue

    private func belongsToActive(_ a: PendingAction) -> Bool {
        a.accountId == nil || a.accountId == accountId
    }

    /// Replays the active account's queued actions in order. Safe to call often
    /// (every refresh, app foreground). A transient failure stops the run (still
    /// offline); a permanent one (deleted post, "already liked") drops that entry
    /// so it can never block the rest of the queue.
    func flush(client: XClient) async {
        guard !flushing, queue.contains(where: belongsToActive) else { return }
        flushing = true
        defer { flushing = false }
        let account = accountId
        while let action = queue.first(where: belongsToActive) {
            let key = Key(kind: action.kind, tweetId: action.tweetId)
            // A worker is already sending a newer state for this post.
            if running.contains(key) { removeQueued(key, account: account); continue }
            do {
                try await send(action.kind, on: action.on, tweetId: action.tweetId, client: client)
                guard account == accountId else { return }
                confirmed[key] = action.on
                remove(action)
            } catch {
                guard account == accountId else { return }
                let e = XError.from(error)
                lastError = e
                if e.isTransientWhileOffline { return }
                remove(action)
            }
        }
    }

    private func enqueue(_ action: PendingAction) {
        queue.removeAll { $0.kind == action.kind && $0.tweetId == action.tweetId && $0.accountId == action.accountId }
        queue.append(action)
        saveQueue()
    }

    private func removeQueued(_ key: Key, account: String?) {
        let before = queue.count
        queue.removeAll { $0.kind == key.kind && $0.tweetId == key.tweetId
            && ($0.accountId == nil || $0.accountId == account) }
        if queue.count != before { saveQueue() }
    }

    private func remove(_ action: PendingAction) {
        if let i = queue.firstIndex(of: action) { queue.remove(at: i) }
        saveQueue()
    }

    private func loadQueue() {
        guard let data = UserDefaults.standard.data(forKey: Self.queueKey),
              let decoded = try? JSONDecoder().decode([PendingAction].self, from: data) else {
            pendingCount = 0
            return
        }
        queue = decoded
        updatePendingCount()
    }

    private func saveQueue() {
        updatePendingCount()
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: Self.queueKey)
        }
    }

    private func updatePendingCount() {
        pendingCount = queue.filter(belongsToActive).count
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
