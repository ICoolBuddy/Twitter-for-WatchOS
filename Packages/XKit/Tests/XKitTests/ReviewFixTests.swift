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

    // MARK: Body-level GraphQL errors (2026-11-20 review, net-1/-3/-5)

    /// `ViewerBadgeCounts` answers 200 with an auth error and `data: {viewer_v2: {}}`.
    /// That must be an auth failure, not "zero notifications".
    func testAuthCodeWithDataIsUnauthorized() {
        let e = XError.graphQLBodyError(codes: [32], messages: ["Could not authenticate you."],
                                        hasData: true, isMutation: false)
        XCTAssertEqual(e, .unauthorized)
    }

    /// 89/215 describe *this request's* auth data, not the account's session: expiring
    /// the session for them made the app flip between logged out and logged in.
    func testRequestAuthCodesDoNotExpireTheSession() {
        XCTAssertNotEqual(XError.graphQLBodyError(codes: [89], messages: ["invalid token"],
                                                  hasData: false, isMutation: false), .unauthorized)
        XCTAssertNotEqual(XError.graphQLBodyError(codes: [215], messages: ["bad auth"],
                                                  hasData: false, isMutation: false), .unauthorized)
    }

    func testNamedSchemaCodeSuggestsEndpointRefresh() {
        let e = XError.graphQLBodyError(codes: [], names: ["GRAPHQL_VALIDATION_FAILED"],
                                        messages: ["must be defined"], hasData: true, isMutation: false)
        XCTAssertNotNil(e)
        XCTAssertEqual(e?.recovery, .refreshEndpoints)
    }

    func testRateLimitCode88() {
        let e = XError.graphQLBodyError(codes: [88], messages: ["Rate limit exceeded"],
                                        hasData: false, isMutation: false)
        XCTAssertEqual(e, .rateLimited(until: nil))
        XCTAssertEqual(e?.recovery, .wait)
    }

    func testSchemaCodeSuggestsEndpointRefresh() {
        let e = XError.graphQLBodyError(codes: [336], messages: ["schema"],
                                        hasData: false, isMutation: false)
        XCTAssertNotNil(e)
        XCTAssertEqual(e?.recovery, .refreshEndpoints)
    }

    /// A mutation that reports an error did not do what was asked, even with data.
    func testMutationErrorWithDataFails() {
        let e = XError.graphQLBodyError(codes: [999], messages: ["nope"],
                                        hasData: true, isMutation: true)
        XCTAssertEqual(e, .graphQL(["nope"]))
    }

    /// Reads keep working through X's soft per-item errors.
    func testReadSoftErrorWithDataIsTolerated() {
        XCTAssertNil(XError.graphQLBodyError(codes: [999], messages: ["soft"],
                                             hasData: true, isMutation: false))
    }

    func testGraphQLBaseHostAllowList() {
        XCTAssertTrue(EndpointConfig.isAllowedGraphQLBase("https://x.com/i/api/graphql"))
        XCTAssertTrue(EndpointConfig.isAllowedGraphQLBase("https://api.x.com/graphql"))
        XCTAssertFalse(EndpointConfig.isAllowedGraphQLBase("http://x.com/i/api/graphql"))
        XCTAssertFalse(EndpointConfig.isAllowedGraphQLBase("https://evil.example/graphql"))
        var cfg = EndpointConfig.bundled
        let poisoned = EndpointConfig(updatedAt: "x", bearer: "", graphqlBase: "https://evil.example",
                                      operations: [:], featureValues: [:], signer: nil, legacySigner: nil)
        cfg = cfg.merging(poisoned)
        XCTAssertEqual(cfg.graphqlBase, EndpointConfig.bundled.graphqlBase)
    }

    func testRelativeTimeOldDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-30 * 86400)
        XCTAssertFalse(RelativeTime.short(old, now: now).isEmpty)
        XCTAssertEqual(RelativeTime.short(now.addingTimeInterval(-90), now: now), "1m")
    }
}
