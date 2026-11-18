#if DEBUG
import Foundation
import XKit

/// The fixture JSON shipped in `PerchWatch/Debug/Fixtures/`, parsed with XKit's
/// own parsers so the screenshot harness exercises the same code as the app.
struct FixtureLibrary: Sendable {
    /// Focal tweet of `tweet_detail.json` (the "post" screenshot).
    static let postID = "1860000000000000011"
    /// Long post in `home_timeline.json` (clamping / "Show more" screenshot).
    static let longPostID = "1860000000000000040"

    let home: TimelinePage
    let threadJSON: JSON
    let profileJSON: JSON
    let userTweetsJSON: JSON
    let notificationsJSON: JSON
    let badgeJSON: JSON
    let dmJSON: JSON
    let searchJSON: JSON

    /// The logged-in account (v1 `user_by_screen_name.json`).
    let viewer: XUser
    /// The profile opened by the "profile" screenshot: the v2-schema user
    /// (`legacy: null`) from `v2_user.json`, so the screenshot covers R1.
    let profileUser: XUser

    /// First post of the home fixture.
    var firstFeedTweet: XTweet? { home.tweets.first }

    /// The focal post of `tweet_detail.json` (used for replies).
    var focalTweet: XTweet? {
        XParser.thread(threadJSON, focalId: Self.postID).focal
    }

    /// The "post" screenshot opens the focal tweet because it has replies.
    var postTweet: XTweet? { focalTweet ?? firstFeedTweet }

    var longPost: XTweet? {
        home.tweets.first { $0.id == Self.longPostID }
    }

    /// The deliberately very tall photo (aspect ratio < 0.45) in the home fixture.
    var tallMedia: XMedia? {
        home.tweets.flatMap(\.media).first { $0.type == .photo && $0.aspectRatio < 0.45 }
    }

    /// The video in the home fixture (exercises the downloader once opened).
    var videoMedia: XMedia? {
        home.tweets.flatMap(\.media).first { $0.type == .video }
    }

    /// Media viewer pages: tall photo first, then the video.
    var mediaItems: [XMedia] { [tallMedia, videoMedia].compactMap { $0 } }

    // MARK: Loading

    static func load(bundle: Bundle = .main) -> FixtureLibrary? {
        guard let homeJSON = json("home_timeline", bundle: bundle) else { return nil }
        let threadJSON = json("tweet_detail", bundle: bundle) ?? .null
        let viewerJSON = json("user_by_screen_name", bundle: bundle) ?? .null
        // `v2_user.json` is a UserByScreenName response with `legacy: null`.
        let profileJSON = json("v2_user", bundle: bundle) ?? viewerJSON
        let fallback = XUser(id: "1001", name: "Ada Example", screenName: "ada_example")
        let viewer = XParser.userResult(viewerJSON) ?? fallback
        return FixtureLibrary(
            home: XParser.timeline(homeJSON),
            threadJSON: threadJSON,
            profileJSON: profileJSON,
            userTweetsJSON: json("user_tweets", bundle: bundle) ?? .null,
            notificationsJSON: json("notifications", bundle: bundle) ?? .null,
            badgeJSON: json("badge_counts", bundle: bundle) ?? .null,
            dmJSON: json("dm_inbox", bundle: bundle) ?? .null,
            searchJSON: json("search_people", bundle: bundle) ?? .null,
            viewer: viewer,
            profileUser: XParser.userResult(profileJSON) ?? viewer
        )
    }

    private static func json(_ name: String, bundle: Bundle) -> JSON? {
        // XcodeGen adds the JSON files to Copy Bundle Resources (flattened), but
        // keep a subdirectory lookup so moving them into a folder reference works too.
        let url = bundle.url(forResource: name, withExtension: "json")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json", subdirectory: "Debug/Fixtures")
        guard let url, let data = try? Data(contentsOf: url), let json = try? JSON(data: data) else {
            return nil
        }
        return json
    }
}

/// `XClient` that serves the bundled fixture JSON and never touches the network.
struct FixtureXClient: XClient {
    let library: FixtureLibrary
    /// `longpost`: put the long post first so it is visible without scrolling.
    var longPostFirst = false

    // MARK: Timelines

    func homeTimeline(_ kind: HomeKind, cursor: String?, context: HomeRequestContext,
                      seenTweetIds: [String]) async throws -> TimelinePage {
        guard cursor == nil else { return TimelinePage(items: [], topCursor: nil, bottomCursor: nil) }
        var items = library.home.items
        // crown-lab: `-PerchFixtureFirst <tweet id>` puts that post first, so a media
        // scenario can open it without scrolling past autoplaying media.
        if let first = UserDefaults.standard.string(forKey: "PerchFixtureFirst"),
           let index = items.firstIndex(where: { $0.tweets.first?.id == first }) {
            items.insert(items.remove(at: index), at: 0)
        }
        if longPostFirst, let long = library.longPost {
            items.removeAll { $0.tweets.first?.id == long.id }
            items.insert(.tweet(long), at: 0)
        }
        return TimelinePage(items: items, topCursor: "fixture-home-top", bottomCursor: nil)
    }

    func tweetDetail(id: String, cursor: String?) async throws -> ThreadPage {
        guard cursor == nil else { return ThreadPage(focal: nil, ancestors: [], replies: [], bottomCursor: nil) }
        let page = XParser.thread(library.threadJSON, focalId: id)
        if page.focal != nil { return page }
        let fallback = XParser.thread(library.threadJSON, focalId: FixtureLibrary.postID)
        if let tweet = library.home.tweets.first(where: { $0.id == id }) {
            return ThreadPage(focal: tweet, ancestors: [], replies: fallback.replies, bottomCursor: nil)
        }
        return fallback
    }

    func userTweets(userId: String, includeReplies: Bool, cursor: String?) async throws -> TimelinePage {
        guard cursor == nil else { return TimelinePage(items: [], topCursor: nil, bottomCursor: nil) }
        return XParser.timeline(library.userTweetsJSON)
    }

    // crown-lab: Likes / Bookmarks serve the home posts so the pushed lists are long
    // enough to scroll (an empty list cannot show whether the crown reached it).
    func likes(userId: String, cursor: String?) async throws -> TimelinePage {
        guard cursor == nil else { return TimelinePage(items: [], topCursor: nil, bottomCursor: nil) }
        return TimelinePage(items: library.home.items, topCursor: nil, bottomCursor: nil)
    }

    func bookmarks(cursor: String?) async throws -> TimelinePage {
        guard cursor == nil else { return TimelinePage(items: [], topCursor: nil, bottomCursor: nil) }
        return TimelinePage(items: library.home.items, topCursor: nil, bottomCursor: nil)
    }

    func search(_ query: String, product: SearchProduct, cursor: String?) async throws -> TimelinePage {
        guard cursor == nil else { return TimelinePage(items: [], topCursor: nil, bottomCursor: nil) }
        return XParser.timeline(library.searchJSON)
    }

    // MARK: Users

    func viewer() async throws -> XUser { library.viewer }

    func user(screenName: String) async throws -> XUser {
        if screenName.caseInsensitiveCompare(library.profileUser.screenName) == .orderedSame {
            return library.profileUser
        }
        let authors = library.home.tweets.map(\.author)
        if let user = authors.first(where: { $0.screenName.caseInsensitiveCompare(screenName) == .orderedSame }) {
            return user
        }
        return library.profileUser
    }

    func user(id: String) async throws -> XUser {
        if id == library.profileUser.id { return library.profileUser }
        if let user = library.home.tweets.map(\.author).first(where: { $0.id == id }) { return user }
        return library.profileUser
    }

    // MARK: Actions (no-ops: nothing is sent anywhere)

    func setLiked(_ liked: Bool, tweetId: String) async throws {}
    func setRetweeted(_ retweeted: Bool, tweetId: String) async throws {}
    func setBookmarked(_ bookmarked: Bool, tweetId: String) async throws {}
    func createTweet(text: String, replyTo: String?) async throws -> XTweet? { nil }
    func deleteTweet(id: String) async throws {}
    func setFollowing(_ follow: Bool, userId: String) async throws {}

    // MARK: Notifications

    func notifications(_ kind: NotificationKind, cursor: String?) async throws -> NotificationsPage {
        guard cursor == nil else { return NotificationsPage(notifications: [], topCursor: nil, bottomCursor: nil) }
        return XParser.notifications(library.notificationsJSON)
    }

    func badgeCounts() async throws -> XBadgeCounts {
        XParser.badgeCounts(library.badgeJSON)
    }

    func markNotificationsSeen(topCursor: String) async throws {}

    // MARK: DMs

    func dmInbox() async throws -> [DMConversation] {
        DMParser.inbox(library.dmJSON, viewerId: library.viewer.id)
    }

    func dmMessages(conversationId: String) async throws -> (messages: [DMMessage], users: [String: XUser]) {
        DMParser.conversation(library.dmJSON)
    }

    func sendDM(conversationId: String, text: String) async throws {}
}
#endif
