import XCTest
@testable import XKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records requests and replies with canned responses.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { var status: Int; var body: Data; var headers: [String: String] = [:] }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    private func next(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
        return replies.isEmpty ? Reply(status: 200, body: Data("{}".utf8)) : replies.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let r = next(request)
        let resp = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        return (r.body, resp)
    }
}

final class ClientTests: XCTestCase {
    func makeStore() async -> XSessionStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = XSessionStore(keychain: KeychainStore(service: "test-\(UUID().uuidString)"), directory: dir)
        await store.setCredentials(XCredentials(authToken: String(repeating: "a", count: 40),
                                                ct0: String(repeating: "b", count: 64), twid: "u%3D2000"))
        await store.setMaterial(TransactionMaterial(verificationKey: "apq2SfoM1EWywcDsmgNQPSj3jOxdYOEh3+PaeD5ZUmrl3Nof03MzwPFtjNK+Tvo1",
                                                    animationKey: "81ec7d100100", source: "test"))
        return store
    }

    func testBundledEndpointsHaveAllOperations() {
        let cfg = EndpointConfig.bundled
        for op in Operation.allCases { XCTAssertNotNil(cfg.info(op), "missing \(op.rawValue) in endpoints.json") }
        XCTAssertEqual(cfg.bearer, EndpointConfig.publicBearer)
        XCTAssertEqual(cfg.signer?.indices.count, 4)
        XCTAssertFalse(cfg.features(for: .homeTimeline).object.isEmpty)
    }

    func testRootAndBundledEndpointsMatch() throws {
        // Repo root endpoints.json (remote-override source) must equal the bundled copy.
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("endpoints.json")
        guard FileManager.default.fileExists(atPath: root.path) else { throw XCTSkip("repo root not available") }
        let a = try EndpointConfig.decode(Data(contentsOf: root))
        XCTAssertEqual(a, EndpointConfig.bundled)
    }

    func testGraphQLGetRequestShape() async throws {
        let store = await makeStore()
        let body = try JSONSerialization.data(withJSONObject: ["data": ["user": ["result": [:]]]])
        let stub = StubTransport([.init(status: 200, body: body)])
        let client = LiveXClient(store: store, transport: stub, log: RequestLog(), limiter: RateLimiter(minimumGap: 0))
        _ = try? await client.user(screenName: "ada_example")
        let req = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(req.httpMethod, "GET")
        let url = try XCTUnwrap(req.url?.absoluteString)
        XCTAssertTrue(url.hasPrefix("https://x.com/i/api/graphql/"), url)
        XCTAssertTrue(url.contains("/UserByScreenName?variables=%7B"), url)
        XCTAssertTrue(url.contains("&features=%7B"), url)
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-csrf-token"), String(repeating: "b", count: 64))
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-twitter-auth-type"), "OAuth2Session")
        XCTAssertEqual(req.value(forHTTPHeaderField: "x-twitter-active-user"), "yes")
        XCTAssertTrue(req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer AAAA") ?? false)
        XCTAssertTrue(req.value(forHTTPHeaderField: "Cookie")?.contains("auth_token=") ?? false)
        XCTAssertNotNil(req.value(forHTTPHeaderField: "x-client-transaction-id"))
    }

    func testMutationIsPostWithQueryId() async throws {
        let store = await makeStore()
        let stub = StubTransport([.init(status: 200, body: Data(#"{"data":{"favorite_tweet":"Done"}}"#.utf8))])
        let client = LiveXClient(store: store, transport: stub, log: RequestLog(), limiter: RateLimiter(minimumGap: 0))
        try await client.setLiked(true, tweetId: "123")
        let req = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        let body = try JSON(data: XCTUnwrap(req.httpBody))
        XCTAssertEqual(body["variables"]["tweet_id"].string, "123")
        XCTAssertEqual(body["queryId"].string, EndpointConfig.bundled.info(.favoriteTweet)?.queryId)
    }

    func testStatusMapping() async {
        let store = await makeStore()
        func run(_ status: Int, _ body: String = "{}") async -> XError? {
            let stub = StubTransport([.init(status: status, body: Data(body.utf8))])
            let client = LiveXClient(store: store, transport: stub, log: RequestLog(), limiter: RateLimiter(minimumGap: 0))
            do { _ = try await client.badgeCounts(); return nil } catch { return error as? XError }
        }
        let e401 = await run(401)
        XCTAssertEqual(e401, .unauthorized)
        let e404 = await run(404)
        XCTAssertEqual(e404, .notFound)
        let e403 = await run(403, #"{"errors":[{"code":326,"message":"Account locked"}]}"#)
        XCTAssertEqual(e403, .forbidden("Account locked"))
        if case .rateLimited = await run(429) {} else { XCTFail("429 must map to rateLimited") }
        let eGQL = await run(200, #"{"errors":[{"message":"boom"}]}"#)
        XCTAssertEqual(eGQL, .graphQL(["boom"]))
    }

    func testRateLimiterBacksOff() async throws {
        let limiter = RateLimiter(minimumGap: 0)
        let now = Date()
        let until = await limiter.didReceive(status: 429, resetEpoch: nil, now: now)
        XCTAssertEqual(until?.timeIntervalSince(now) ?? 0, 60, accuracy: 0.01)
        do { try await limiter.acquire(now: now.addingTimeInterval(10)); XCTFail("should throw") } catch {}
        let until2 = await limiter.didReceive(status: 429, resetEpoch: nil, now: now)
        XCTAssertEqual(until2?.timeIntervalSince(now) ?? 0, 120, accuracy: 0.01)
    }

    func testCt0RotationFromSetCookie() async throws {
        let store = await makeStore()
        let stub = StubTransport([.init(status: 200, body: Data(#"{"data":{}}"#.utf8),
                                        headers: ["Set-Cookie": "ct0=newtoken123456; Path=/; Domain=.x.com; Secure"])])
        let client = LiveXClient(store: store, transport: stub, log: RequestLog(), limiter: RateLimiter(minimumGap: 0))
        _ = try await client.badgeCounts()
        let ct0 = await store.credentials?.ct0
        XCTAssertEqual(ct0, "newtoken123456")
    }

    func test404RefreshesMaterialOnce() async throws {
        let store = await makeStore()
        let stub = StubTransport([.init(status: 404, body: Data()), .init(status: 200, body: Data(#"{"data":{}}"#.utf8))])
        let counter = Counter()
        let client = LiveXClient(store: store, transport: stub, log: RequestLog(), limiter: RateLimiter(minimumGap: 0),
                                 refreshMaterial: {
                                     await counter.inc()
                                     return TransactionMaterial(verificationKey: "AAAA", animationKey: "k", source: "fresh")
                                 })
        _ = try await client.badgeCounts()
        let n = await counter.value
        XCTAssertEqual(n, 1)
        XCTAssertEqual(stub.requests.count, 2)
        let src = await store.material?.source
        XCTAssertEqual(src, "fresh")
    }

    func testRedactor() {
        let c = XCredentials(authToken: "0123456789abcdef0123456789abcdef01234567", ct0: String(repeating: "f", count: 64))
        let s = Redactor.redact("Cookie: auth_token=0123456789abcdef0123456789abcdef01234567; ct0=\(c.ct0)", credentials: c)
        XCTAssertFalse(s.contains(c.authToken))
        XCTAssertFalse(s.contains(c.ct0))
        XCTAssertTrue(c.looksValid)
        XCTAssertEqual(XCredentials(authToken: "a", ct0: "b", twid: "u%3D42").userId, "42")
    }

    func testSyncPayloadRoundTrip() async throws {
        let p = SyncPayload(command: .update, credentials: XCredentials(authToken: "a", ct0: "b"),
                            config: EndpointConfig.bundled,
                            material: TransactionMaterial(verificationKey: "k", animationKey: "a", source: "s"))
        let back = try XCTUnwrap(SyncPayload.from(dictionary: p.dictionary()))
        XCTAssertEqual(back.credentials, p.credentials)
        XCTAssertEqual(back.material?.animationKey, "a")
        let store = await makeStore()
        await SyncPayload(command: .logout).apply(to: store)
        let creds = await store.credentials
        XCTAssertNil(creds)
    }

    func testDiscoveryParsing() {
        let js = #"e.exports={queryId:"AbC",operationName:"HomeTimeline",operationType:"query",metadata:{featureSwitches:["f1","f2"],fieldToggles:["t1"]}}"#
        let ops = EndpointDiscovery.operations(in: js)
        XCTAssertEqual(ops["HomeTimeline"]?.queryId, "AbC")
        XCTAssertEqual(ops["HomeTimeline"]?.features, ["f1", "f2"])
        XCTAssertEqual(ops["HomeTimeline"]?.fieldToggles, ["t1"])

        let html = #"<script src="https://abs.twimg.com/responsive-web/client-web/main.abc123a.js"></script>"# +
            #"{1:"bundle.Home",2:"ondemand.s"}{1:"0123456789abcdef",2:"fedcba9876543210"},59924:"ondemand.s""# +
            #""featureSwitch":{"defaultConfig":{"f1":{"value":true},"f2":{"value":false}}}"#
        let scripts = EndpointDiscovery.legacyScripts(html).map(\.absoluteString)
        XCTAssertTrue(scripts.contains("https://abs.twimg.com/responsive-web/client-web/main.abc123a.js"))
        XCTAssertTrue(scripts.contains("https://abs.twimg.com/responsive-web/client-web/bundle.Home.0123456789abcdefa.js"))
        XCTAssertEqual(EndpointDiscovery.featureDefaults(html), ["f1": true, "f2": false])
    }
}

actor Counter {
    var value = 0
    func inc() { value += 1 }
}
