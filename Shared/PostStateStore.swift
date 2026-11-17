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
        perform(t, new: s, old: old) { try await client.setLiked(s.liked, tweetId: t.id) }
    }

    func toggleRetweet(_ t: XTweet, client: XClient) {
        var s = state(for: t)
        let old = s
        s.retweeted.toggle()
        s.retweetCount = max(0, s.retweetCount + (s.retweeted ? 1 : -1))
        perform(t, new: s, old: old) { try await client.setRetweeted(s.retweeted, tweetId: t.id) }
    }

    func toggleBookmark(_ t: XTweet, client: XClient) {
        var s = state(for: t)
        let old = s
        s.bookmarked.toggle()
        perform(t, new: s, old: old) { try await client.setBookmarked(s.bookmarked, tweetId: t.id) }
    }

    private func perform(_ t: XTweet, new: State, old: State, _ op: @escaping () async throws -> Void) {
        overrides[t.id] = new
        Haptics.click()
        Task {
            do {
                try await op()
            } catch {
                // Roll back.
                overrides[t.id] = old
                lastError = XError.from(error)
                Haptics.failure()
            }
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
