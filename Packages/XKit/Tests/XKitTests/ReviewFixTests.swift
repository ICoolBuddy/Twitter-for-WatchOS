import XCTest
@testable import XKit

/// Regression tests for the 2026-11-17 review fixes (text slicing, quote links).
final class ReviewFixTests: XCTestCase {

    private func tweet(_ body: String) throws -> XTweet {
        let json = try JSON(data: Data(#"""
        {"__typename":"Tweet","rest_id":"100",
         "core":{"user_results":{"result":{"__typename":"User","rest_id":"1",
           "core":{"screen_name":"a","name":"A"}}}},
         \#(body)}
        """#.utf8))
        return try XCTUnwrap(XParser.tweet(json))
    }

    /// `display_text_range` counted on the unescaped text must not cut the tail
    /// of a post that contains `&`.
    func testEscapedTextIsNotTruncated() throws {
        // "Tom & Jerry rule" = 16 characters unescaped (21 escaped).
        let t = try tweet(#""full_text":"Tom &amp; Jerry rule","display_text_range":[0,16]"#)
        XCTAssertEqual(t.text, "Tom & Jerry rule")
    }

    /// A reply's leading @mention is still stripped after decoding first.
    func testReplyMentionStillStripped() throws {
        let t = try tweet(#""full_text":"@bob fish &amp; chips","display_text_range":[5,20]"#)
        XCTAssertEqual(t.text, "fish & chips")
    }

    /// The quoted post is shown as a card: its permalink leaves the text.
    func testQuotePermalinkRemoved() throws {
        let t = try tweet(#"""
        "full_text":"So true https://t.co/QUOTE",
        "entities":{"urls":[{"url":"https://t.co/QUOTE",
          "expanded_url":"https://x.com/b/status/200"}]},
        "quoted_status_permalink":{"url":"https://t.co/QUOTE"},
        "quoted_status_result":{"result":{"__typename":"Tweet","rest_id":"200",
          "core":{"user_results":{"result":{"__typename":"User","rest_id":"2",
            "core":{"screen_name":"b","name":"B"}}}},
          "full_text":"Original"}}
        """#)
        XCTAssertEqual(t.text, "So true")
        XCTAssertEqual(t.quotedTweet?.value.text, "Original")
    }

    /// Other links are still expanded.
    func testOtherLinksExpanded() throws {
        let t = try tweet(#"""
        "full_text":"Read https://t.co/L",
        "entities":{"urls":[{"url":"https://t.co/L","expanded_url":"https://example.com/a"}]}
        """#)
        XCTAssertEqual(t.text, "Read https://example.com/a")
    }

    func testForbiddenSuggestsEndpointRefresh() {
        XCTAssertEqual(XError.forbidden("").recovery, .refreshEndpoints)
        XCTAssertEqual(XError.unauthorized.recovery, .relogin)
    }

    func testRelativeTimeOldDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-30 * 86400)
        XCTAssertFalse(RelativeTime.short(old, now: now).isEmpty)
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-90), now: now), "1m")
    }
}
