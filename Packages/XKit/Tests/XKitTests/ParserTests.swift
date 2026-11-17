import XCTest
@testable import XKit

final class ParserTests: XCTestCase {
    func testJSONBasics() throws {
        let j = try JSON(data: Data(#"{"a":{"b":[1,true,"x",null,2.5]},"n":"7"}"#.utf8))
        XCTAssertEqual(j["a"]["b"][0].int, 1)
        XCTAssertEqual(j["a"]["b"][1].bool, true)
        XCTAssertEqual(j["a"]["b"][2].string, "x")
        XCTAssertTrue(j["a"]["b"][3].isNull)
        XCTAssertEqual(j["a"]["b"][4].double, 2.5)
        XCTAssertTrue(j["missing"]["deeper"][3].isNull)
        XCTAssertEqual(j["n"].int, 7)
        XCTAssertEqual(j[path: "a.b"].array.count, 5)
    }

    func testHomeTimeline() throws {
        let page = XParser.timeline(MockData.json("home_timeline"))
        XCTAssertEqual(page.topCursor, "DAABCgABTOP")
        XCTAssertEqual(page.bottomCursor, "DAABCgABBOTTOM")
        // tweet, visibility-wrapped, repost, quote, conversation, tombstone — no promoted / who-to-follow / unknown.
        XCTAssertEqual(page.items.count, 6, page.items.map(\.id).joined(separator: ","))
        XCTAssertFalse(page.tweets.contains { $0.id == "1860000000000000099" }, "promoted must be skipped")

        guard case .tweet(let t1) = page.items[0] else { return XCTFail() }
        XCTAssertEqual(t1.author.screenName, "ada_example")
        XCTAssertEqual(t1.author.name, "Ada Example")
        XCTAssertTrue(t1.author.isVerified)
        XCTAssertEqual(t1.text, "Hello from a mock timeline! Read more https://example.com/post")
        XCTAssertEqual(t1.likeCount, 42)
        XCTAssertEqual(t1.retweetCount, 7)
        XCTAssertEqual(t1.replyCount, 3)
        XCTAssertEqual(t1.viewCount, 1680)
        XCTAssertEqual(t1.media.count, 1)
        XCTAssertEqual(t1.media[0].thumbnailURL.absoluteString, "https://pbs.twimg.com/media/Mock700001?format=jpg&name=small")
        XCTAssertNotNil(t1.createdAt)

        guard case .tweet(let t2) = page.items[1] else { return XCTFail() }
        XCTAssertEqual(t2.id, "1860000000000000002")
        XCTAssertEqual(t2.text, "Visibility-wrapped post & entities <3")
        XCTAssertTrue(t2.liked)
        XCTAssertEqual(t2.author.screenName, "bensample", "legacy user shape must still parse")
        XCTAssertTrue(t2.author.following)

        guard case .tweet(let rt) = page.items[2] else { return XCTFail() }
        XCTAssertTrue(rt.isRetweet)
        XCTAssertEqual(rt.author.screenName, "devplace")
        XCTAssertEqual(rt.displayed.author.screenName, "cleo_co")
        XCTAssertEqual(rt.displayed.author.name, "Cleo & Co")
        XCTAssertEqual(rt.displayed.media.first?.type, .video)
        XCTAssertEqual(rt.displayed.media.first?.lowestBitrateMP4?.absoluteString,
                       "https://video.twimg.com/ext_tw_video/1/pu/vid/480x270/lo.mp4")

        guard case .tweet(let q) = page.items[3] else { return XCTFail() }
        XCTAssertEqual(q.quotedTweet?.value.text, "I am the quoted post.")

        guard case .conversation(let conv) = page.items[4] else { return XCTFail() }
        XCTAssertEqual(conv.map(\.id), ["1860000000000000007", "1860000000000000008"])
        XCTAssertEqual(conv[1].text, "Thread part 2/2", "display_text_range strips leading mention")

        guard case .tweet(let tomb) = page.items[5] else { return XCTFail() }
        XCTAssertTrue(tomb.isTombstone)
    }

    func testTweetDetailThread() {
        let thread = XParser.thread(MockData.json("tweet_detail"), focalId: "1860000000000000011")
        XCTAssertEqual(thread.focal?.id, "1860000000000000011")
        XCTAssertEqual(thread.focal?.text, "This is the focal reply with a photo")
        XCTAssertEqual(thread.ancestors.map(\.id), ["1860000000000000010"])
        XCTAssertEqual(thread.replies.count, 2)
        XCTAssertEqual(thread.replies[0].tweets.count, 2)
        XCTAssertEqual(thread.bottomCursor, "DETAILBOTTOM")
    }

    func testNotifications() {
        let page = XParser.notifications(MockData.json("notifications"))
        XCTAssertEqual(page.notifications.count, 3)
        XCTAssertEqual(page.notifications[0].text, "Ada Example and Ben Sample liked your post")
        XCTAssertEqual(page.notifications[0].users.count, 2)
        XCTAssertEqual(page.notifications[0].tweet?.id, "1860000000000000020")
        XCTAssertTrue(page.notifications[0].isUnread)
        XCTAssertEqual(page.notifications[1].icon, "reply_icon")
        XCTAssertTrue(page.notifications[1].isUnread)
        XCTAssertEqual(page.notifications[2].text, "Cleo & Co followed you")
        XCTAssertFalse(page.notifications[2].isUnread)
        XCTAssertEqual(page.bottomCursor, "NOTIFBOTTOM")
    }

    func testUserAndProfileTimeline() throws {
        let u = try XCTUnwrap(XParser.userResult(MockData.json("user_by_screen_name")))
        XCTAssertEqual(u.screenName, "ada_example")
        XCTAssertEqual(u.bio, "Writes about engines. https://example.com")
        XCTAssertEqual(u.followersCount, 5400)
        XCTAssertNotNil(u.avatarLargeURL)

        let p = XParser.timeline(MockData.json("user_tweets"))
        XCTAssertEqual(p.tweets.map(\.id), ["1860000000000000030", "1860000000000000031"], "pinned first")
        XCTAssertEqual(p.bottomCursor, "UTBOTTOM")
    }

    func testPeopleSearch() {
        let p = XParser.timeline(MockData.json("search_people"))
        let users = p.items.compactMap { if case .user(let u) = $0 { return u } else { return nil } }
        XCTAssertEqual(users.map(\.screenName), ["ada_example", "cleo_co"])
    }

    func testDMs() {
        let inbox = DMParser.inbox(MockData.json("dm_inbox"), viewerId: "2000")
        XCTAssertEqual(inbox.count, 2)
        XCTAssertEqual(inbox[0].participants.first?.screenName, "ada_example")
        XCTAssertEqual(inbox[0].lastMessage, "Hi there & welcome")
        XCTAssertTrue(inbox[0].isUnread)
        XCTAssertTrue(inbox[1].isEncrypted)
    }

    func testBadgeCounts() {
        let b = XParser.badgeCounts(MockData.json("badge_counts"))
        XCTAssertEqual(b.notifications, 4)
        XCTAssertEqual(b.dms, 1)
        let legacy = XParser.badgeCounts(["ntab_unread_count": 2, "dm_unread_count": 3, "total_unread_count": 5])
        XCTAssertEqual(legacy, XBadgeCounts(notifications: 2, dms: 3))
    }

    func testToleratesGarbage() {
        XCTAssertEqual(XParser.timeline(.null).items.count, 0)
        XCTAssertEqual(XParser.timeline(["data": ["x": [1, 2, "y"]]]).items.count, 0)
        XCTAssertNil(XParser.tweet(["__typename": "TweetUnavailable"]))
        XCTAssertNil(XParser.tweet(["rest_id": "1"]), "no author → skipped, not crash")
    }

    func testGraphQLErrors() {
        let j: JSON = ["errors": [["message": "Rate limit exceeded", "code": 88]]]
        XCTAssertEqual(XParser.graphQLErrors(j), ["Rate limit exceeded"])
    }

    func testMediaSizeURL() {
        let m = XMedia(id: "1", type: .photo, url: URL(string: "https://pbs.twimg.com/media/ABC.png")!, width: 10, height: 5)
        XCTAssertEqual(m.imageURL(size: "thumb").absoluteString, "https://pbs.twimg.com/media/ABC?format=png&name=thumb")
        XCTAssertEqual(m.aspectRatio, 2)
    }
}
