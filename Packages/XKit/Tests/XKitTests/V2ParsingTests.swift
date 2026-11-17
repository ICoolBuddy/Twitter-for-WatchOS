import XCTest
@testable import XKit

/// The 2026-05 X schema moved `legacy.*` to the top level of results and sends
/// `"legacy": null`. These tests use hand-written v2 JSON (legacy null); the older
/// v1 fixtures in `Fixtures/Mock` cover the "legacy object" shape.
final class V2ParsingTests: XCTestCase {

    // MARK: R1 — flat user

    private let v2UserJSON = #"""
    {"data":{"user":{"result":{
     "__typename":"User",
     "rest_id":"4242",
     "legacy":null,
     "core":{"screen_name":"v2user","name":"V2 User","created_at":"Wed Jan 01 00:00:00 +0000 2020"},
     "avatar":{"image_url":"https://pbs.twimg.com/profile_images/4242/avatar.jpg"},
     "banner":{"image_url":"https://pbs.twimg.com/profile_banners/4242/1700000000/1500x500"},
     "location":{"location":"Berlin, DE"},
     "privacy":{"protected":false},
     "verification":{"verified":true,"verified_type":"blue"},
     "is_blue_verified":true,
     "profile_bio":{"description":"Building &amp; shipping https://t.co/BIOLINK","entities":{"urls":[
       {"url":"https://t.co/BIOLINK","expanded_url":"https://example.org/bio"}]}},
     "relationship_counts":{"followers":1234,"following":321},
     "tweet_counts":{"tweets":9876,"media_tweets":54},
     "action_counts":{"favorites_count":4321},
     "relationship_perspectives":{"following":true,"followed_by":false}
    }}}}
    """#

    func testV2UserWithLegacyNull() throws {
        let json = try JSON(data: Data(v2UserJSON.utf8))
        let user = try XCTUnwrap(XParser.userResult(json))
        XCTAssertEqual(user.id, "4242")
        XCTAssertEqual(user.name, "V2 User")
        XCTAssertEqual(user.screenName, "v2user")
        XCTAssertEqual(user.followersCount, 1234)
        XCTAssertEqual(user.followingCount, 321)
        XCTAssertEqual(user.postsCount, 9876)
        XCTAssertTrue(user.isVerified)
        XCTAssertFalse(user.isProtected)
        XCTAssertTrue(user.following)
        XCTAssertEqual(user.bio, "Building & shipping https://example.org/bio")
        XCTAssertEqual(user.location, "Berlin, DE")
        XCTAssertEqual(user.avatarURL?.absoluteString,
                       "https://pbs.twimg.com/profile_images/4242/avatar.jpg")
        // v2 banner URLs are complete; nothing must be appended.
        XCTAssertEqual(user.bannerURL?.absoluteString,
                       "https://pbs.twimg.com/profile_banners/4242/1700000000/1500x500")
        XCTAssertNotNil(user.createdAt)
    }

    func testV2UserMappingsDoNotOverrideFlatValues() throws {
        // legacy object + explicit flat values: the flat keys win.
        let json = try JSON(data: Data(#"""
        {"rest_id":"7","legacy":{"name":"Legacy Name","followers_count":10},
         "core":{"name":"Flat Name"},"relationship_counts":{"followers":99}}
        """#.utf8))
        let user = try XCTUnwrap(XParser.user(json))
        XCTAssertEqual(user.name, "Legacy Name", "legacy fills a missing flat key")
        XCTAssertEqual(user.followersCount, 10, "a filled flat key is not overridden")
    }

    func testV1UserBannerStillGetsSizeSuffix() throws {
        // Old schema: `profile_banner_url` is a base path that needs a size.
        let json = try JSON(data: Data(#"""
        {"rest_id":"9","legacy":{"screen_name":"old","name":"Old User",
         "profile_banner_url":"https://pbs.twimg.com/profile_banners/9/123"}}
        """#.utf8))
        let user = try XCTUnwrap(XParser.user(json))
        XCTAssertEqual(user.bannerURL?.absoluteString,
                       "https://pbs.twimg.com/profile_banners/9/123/600x200")
    }

    // MARK: R1 — flat tweet

    private func v2TweetJSON(text: String) -> String {
        #"""
        {"data":{"tweetResult":{"result":{
         "__typename":"Tweet",
         "rest_id":"9001",
         "legacy":null,
         "core":{"user_results":{"result":{
           "__typename":"User","rest_id":"4242","legacy":null,
           "core":{"screen_name":"v2user","name":"V2 User"},
           "avatar":{"image_url":"https://pbs.twimg.com/profile_images/4242/avatar.jpg"}}}},
         "full_text":"\#(text)",
         "created_at":"Mon Nov 16 10:00:00 +0000 2026",
         "favorite_count":77,
         "retweet_count":12,
         "reply_count":5,
         "quote_count":1,
         "bookmark_count":2,
         "favorited":true,
         "retweeted":false,
         "bookmarked":true,
         "in_reply_to_screen_name":"someone",
         "in_reply_to_status_id_str":"8000",
         "conversation_id_str":"8000",
         "lang":"en",
         "entities":{"urls":[],"media":[{
           "id_str":"55","media_url_https":"https://pbs.twimg.com/media/V2MEDIA.jpg",
           "type":"photo","original_info":{"width":1000,"height":500},"url":"https://t.co/MEDIA1"}]},
         "extended_entities":{"media":[{
           "id_str":"55","media_url_https":"https://pbs.twimg.com/media/V2MEDIA.jpg",
           "type":"photo","original_info":{"width":1000,"height":500},"url":"https://t.co/MEDIA1"}]},
         "views":{"count":"12345"}
        }}}}
        """#
    }

    func testV2TweetWithLegacyNull() throws {
        let json = try JSON(data: Data(v2TweetJSON(text: "V2 post text https://t.co/MEDIA1").utf8))
        let tweet = try XCTUnwrap(XParser.tweet(json[path: "data.tweetResult.result"]))
        XCTAssertEqual(tweet.id, "9001")
        XCTAssertEqual(tweet.text, "V2 post text")
        XCTAssertEqual(tweet.author.screenName, "v2user")
        XCTAssertEqual(tweet.replyCount, 5)
        XCTAssertEqual(tweet.retweetCount, 12)
        XCTAssertEqual(tweet.likeCount, 77)
        XCTAssertEqual(tweet.quoteCount, 1)
        XCTAssertEqual(tweet.bookmarkCount, 2)
        XCTAssertEqual(tweet.viewCount, 12345)
        XCTAssertTrue(tweet.liked)
        XCTAssertFalse(tweet.retweeted)
        XCTAssertTrue(tweet.bookmarked)
        XCTAssertEqual(tweet.media.count, 1)
        XCTAssertEqual(tweet.media[0].url.absoluteString, "https://pbs.twimg.com/media/V2MEDIA.jpg")
        XCTAssertEqual(tweet.media[0].aspectRatio, 2)
        XCTAssertEqual(tweet.inReplyToScreenName, "someone")
        XCTAssertEqual(tweet.inReplyToStatusId, "8000")
        XCTAssertEqual(tweet.conversationId, "8000")
        XCTAssertEqual(tweet.lang, "en")
        XCTAssertNotNil(tweet.createdAt)
    }

    // MARK: R2 — replies only

    private func user(_ id: String, _ screen: String) -> String {
        """
        {"__typename":"User","rest_id":"\(id)","legacy":null,
         "core":{"screen_name":"\(screen)","name":"User \(id)"}}
        """
    }

    private func tweet(_ id: String, replyTo: String? = nil, conversation: String = "100") -> String {
        let reply = replyTo.map { "\"in_reply_to_status_id_str\":\"\($0)\"," } ?? ""
        return """
        {"__typename":"Tweet","rest_id":"\(id)","legacy":null,
         "core":{"user_results":{"result":\(user("1", "tester"))}},
         "full_text":"Post \(id)","conversation_id_str":"\(conversation)",\(reply)
         "favorite_count":1,"reply_count":0,"retweet_count":0}
        """
    }

    private func entry(_ entryId: String, _ tweet: String) -> String {
        """
        {"entryId":"\(entryId)","content":{"entryType":"TimelineTimelineItem",
         "itemContent":{"itemType":"TimelineTweet","tweet_results":{"result":\(tweet)}}}}
        """
    }

    private func module(_ entryId: String, _ tweets: [String]) -> String {
        let items = tweets.map { t in
            """
            {"item":{"itemContent":{"itemType":"TimelineTweet","tweet_results":{"result":\(t)}}}}
            """
        }.joined(separator: ",")
        return """
        {"entryId":"\(entryId)","content":{"entryType":"TimelineTimelineModule","items":[\(items)]}}
        """
    }

    private func cursor(_ type: String, _ value: String) -> String {
        """
        {"entryId":"cursor-\(type)","content":{"entryType":"TimelineTimelineCursor",
         "cursorType":"\(type)","value":"\(value)"}}
        """
    }

    private func threadJSON(_ entries: [String]) throws -> JSON {
        let body = entries.joined(separator: ",")
        return try JSON(data: Data("""
        {"data":{"threaded_conversation_with_injections_v2":{"instructions":[
          {"type":"TimelineAddEntries","entries":[\(body)]}]}}}
        """.utf8))
    }

    func testThreadKeepsOnlyDirectReplies() throws {
        let json = try threadJSON([
            entry("tweet-100", tweet("100")),
            entry("tweet-101", tweet("101", replyTo: "100")),
            module("conversationthread-102", [tweet("102", replyTo: "100"),
                                              tweet("103", replyTo: "102")]),
            // Two "Discover more" recommendations that happen to reply to the focal post.
            entry("tweetdetailrelatedtweets-901", tweet("901", replyTo: "100")),
            entry("tweetdetailrelatedtweets-903", tweet("903", replyTo: "100")),
            // Unrelated conversation.
            entry("tweet-902", tweet("902", replyTo: "500", conversation: "500")),
            cursor("ShowMoreThreadsPrompt", "PROMPT"),
            cursor("ShowMoreThreads", "MORE"),
            cursor("Bottom", "BOTTOM"),
        ])
        let page = XParser.thread(json, focalId: "100")
        XCTAssertEqual(page.focal?.id, "100")
        XCTAssertEqual(page.replies.count, 2, "focal + 2 replies + 2 related posts → 2 replies")
        XCTAssertEqual(page.replies[0].tweets.map(\.id), ["101"])
        XCTAssertEqual(page.replies[1].tweets.map(\.id), ["102", "103"],
                       "a conversation module keeps its whole chain")
        let replyIds = page.replies.flatMap(\.tweets).map(\.id)
        XCTAssertFalse(replyIds.contains("901"), "related posts are skipped by entry id prefix")
        XCTAssertFalse(replyIds.contains("903"), "related posts are skipped by entry id prefix")
        XCTAssertFalse(replyIds.contains("902"), "unrelated conversations are not replies")
        XCTAssertTrue(page.ancestors.isEmpty)
        XCTAssertEqual(page.bottomCursor, "MORE")
    }

    func testThreadReplyCursorFallbacks() throws {
        let prompt = try threadJSON([
            entry("tweet-100", tweet("100")),
            cursor("ShowMoreThreadsPrompt", "PROMPT"),
            cursor("Bottom", "BOTTOM"),
        ])
        XCTAssertEqual(XParser.thread(prompt, focalId: "100").bottomCursor, "PROMPT")

        let bottom = try threadJSON([
            entry("tweet-100", tweet("100")),
            cursor("Bottom", "BOTTOM"),
        ])
        XCTAssertEqual(XParser.thread(bottom, focalId: "100").bottomCursor, "BOTTOM")
    }

    func testThreadPaginationPageWithoutFocalStillReturnsReplies() throws {
        let json = try threadJSON([
            entry("tweet-201", tweet("201", replyTo: "100")),
            entry("tweet-202", tweet("202", replyTo: "100")),
        ])
        let page = XParser.thread(json, focalId: "100")
        XCTAssertNil(page.focal)
        XCTAssertEqual(page.replies.flatMap(\.tweets).map(\.id), ["201", "202"])
    }
}
