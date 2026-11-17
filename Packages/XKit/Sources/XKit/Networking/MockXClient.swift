import Foundation

/// Bundled, anonymized sample responses (also used by the parser tests).
public enum MockData {
    public static func json(_ name: String) -> JSON {
        let candidates = [
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Mock"),
            Bundle.module.resourceURL?.appendingPathComponent("Mock/\(name).json"),
        ]
        for case let url? in candidates {
            if let d = try? Data(contentsOf: url), let j = try? JSON(data: d) { return j }
        }
        return .null
    }
}

/// Offline client backed by `MockData`. Powers Demo mode and SwiftUI previews.
public actor MockXClient: XClient {
    private var liked: Set<String> = []
    private var latency: UInt64

    public init(latencyMs: UInt64 = 250) { self.latency = latencyMs * 1_000_000 }

    private func pause() async { try? await Task.sleep(nanoseconds: latency) }

    public func homeTimeline(_ kind: HomeKind, cursor: String?) async throws -> TimelinePage {
        await pause()
        var page = XParser.timeline(MockData.json("home_timeline"))
        if cursor != nil { page.bottomCursor = nil }  // one extra page at most
        if kind == .following { page.items.reverse() }
        return page
    }

    public func tweetDetail(id: String, cursor: String?) async throws -> ThreadPage {
        await pause()
        let json = MockData.json("tweet_detail")
        var t = XParser.thread(json, focalId: "1860000000000000011")
        // Make any tapped post the focal one in demo mode.
        if t.focal?.id != id, let home = XParser.timeline(MockData.json("home_timeline")).tweets.first(where: { $0.id == id }) {
            t = ThreadPage(focal: home, ancestors: [], replies: t.replies, bottomCursor: nil)
        }
        return t
    }

    public func setLiked(_ v: Bool, tweetId: String) async throws {
        await pause()
        if v { liked.insert(tweetId) } else { liked.remove(tweetId) }
    }
    public func setRetweeted(_ v: Bool, tweetId: String) async throws { await pause() }
    public func setBookmarked(_ v: Bool, tweetId: String) async throws { await pause() }

    public func createTweet(text: String, replyTo: String?) async throws -> XTweet? {
        await pause()
        let me = XParser.user(MockData.json("user_by_screen_name")[path: "data.user.result"]) ?? .unknown
        return XTweet(id: UUID().uuidString, text: text, author: me, createdAt: Date(), inReplyToStatusId: replyTo)
    }
    public func deleteTweet(id: String) async throws { await pause() }

    public func notifications(_ kind: NotificationKind, cursor: String?) async throws -> NotificationsPage {
        await pause()
        var p = XParser.notifications(MockData.json("notifications"))
        if kind == .mentions { p.notifications = p.notifications.filter { $0.icon == "reply_icon" } }
        if cursor != nil { p.notifications = []; p.bottomCursor = nil }
        return p
    }

    public func badgeCounts() async throws -> XBadgeCounts {
        seen ? XBadgeCounts(notifications: 0, dms: 1) : XParser.badgeCounts(MockData.json("badge_counts"))
    }
    private var seen = false
    public func markNotificationsSeen(topCursor: String) async throws { seen = true }

    public func viewer() async throws -> XUser {
        XUser(id: "2000", name: "Perch Tester", screenName: "perch_tester",
              bio: "Demo mode — log in on your iPhone to see your real account.", followersCount: 42, followingCount: 7)
    }

    public func user(screenName: String) async throws -> XUser {
        await pause()
        guard var u = XParser.userResult(MockData.json("user_by_screen_name")) else { throw XError.decoding("mock") }
        if screenName.lowercased() != u.screenName.lowercased() { u.screenName = screenName; u.name = screenName }
        return u
    }

    public func user(id: String) async throws -> XUser { try await user(screenName: "ada_example") }

    public func userTweets(userId: String, includeReplies: Bool, cursor: String?) async throws -> TimelinePage {
        await pause()
        var p = XParser.timeline(MockData.json("user_tweets"))
        if cursor != nil { p = TimelinePage(items: []) }
        return p
    }

    public func setFollowing(_ follow: Bool, userId: String) async throws { await pause() }

    public func search(_ query: String, product: SearchProduct, cursor: String?) async throws -> TimelinePage {
        await pause()
        if cursor != nil { return TimelinePage(items: []) }
        if product == .people { return XParser.timeline(MockData.json("search_people")) }
        var p = XParser.timeline(MockData.json("home_timeline"))
        let q = query.lowercased()
        p.items = p.items.filter { $0.tweets.contains { $0.displayed.text.lowercased().contains(q) } || q.isEmpty }
        p.bottomCursor = nil
        return p
    }

    public func bookmarks(cursor: String?) async throws -> TimelinePage {
        await pause()
        var p = XParser.timeline(MockData.json("user_tweets"))
        p.bottomCursor = nil
        return p
    }

    public func dmInbox() async throws -> [DMConversation] {
        await pause()
        return DMParser.inbox(MockData.json("dm_inbox"), viewerId: "2000")
    }

    public func dmMessages(conversationId: String) async throws -> (messages: [DMMessage], users: [String: XUser]) {
        await pause()
        let root = MockData.json("dm_inbox")["inbox_initial_state"]
        let wrapped: JSON = ["conversation_timeline": ["entries": root["entries"], "users": root["users"]]]
        return DMParser.conversation(wrapped)
    }

    public func sendDM(conversationId: String, text: String) async throws { await pause() }
}
