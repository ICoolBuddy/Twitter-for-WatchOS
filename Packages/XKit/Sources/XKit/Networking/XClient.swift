import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HomeKind: String, Codable, Sendable, CaseIterable {
    case forYou, following
}

public enum NotificationKind: String, Codable, Sendable, CaseIterable {
    case all = "All", mentions = "Mentions"
}

public enum SearchProduct: String, Sendable, CaseIterable {
    case top = "Top", latest = "Latest", people = "People", media = "Media"
}

/// Everything the UI needs from X. `LiveXClient` talks to x.com.
public protocol XClient: Sendable {
    func homeTimeline(_ kind: HomeKind, cursor: String?) async throws -> TimelinePage
    func tweetDetail(id: String, cursor: String?) async throws -> ThreadPage
    func setLiked(_ liked: Bool, tweetId: String) async throws
    func setRetweeted(_ retweeted: Bool, tweetId: String) async throws
    func setBookmarked(_ bookmarked: Bool, tweetId: String) async throws
    func createTweet(text: String, replyTo: String?) async throws -> XTweet?
    func deleteTweet(id: String) async throws
    func notifications(_ kind: NotificationKind, cursor: String?) async throws -> NotificationsPage
    func badgeCounts() async throws -> XBadgeCounts
    /// Tells X the notifications up to `topCursor` were seen (clears the badge).
    func markNotificationsSeen(topCursor: String) async throws
    func viewer() async throws -> XUser
    func user(screenName: String) async throws -> XUser
    func user(id: String) async throws -> XUser
    func userTweets(userId: String, includeReplies: Bool, cursor: String?) async throws -> TimelinePage
    func setFollowing(_ follow: Bool, userId: String) async throws
    func search(_ query: String, product: SearchProduct, cursor: String?) async throws -> TimelinePage
    func bookmarks(cursor: String?) async throws -> TimelinePage
    func dmInbox() async throws -> [DMConversation]
    func dmMessages(conversationId: String) async throws -> (messages: [DMMessage], users: [String: XUser])
    func sendDM(conversationId: String, text: String) async throws
}

/// Produces fresh transaction material (iPhone scrapes x.com; Watch may too).
public typealias MaterialRefresher = @Sendable () async throws -> TransactionMaterial

public actor LiveXClient: XClient {
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15"
    public static let pageSize = 20

    private let store: XSessionStore
    private let transport: HTTPTransport
    private let log: RequestLog
    private let limiter: RateLimiter
    private let refreshMaterial: MaterialRefresher?
    private var refreshingMaterial: Task<TransactionMaterial, Error>?

    public init(store: XSessionStore, transport: HTTPTransport = URLSessionTransport(), log: RequestLog = .shared,
                limiter: RateLimiter = RateLimiter(), refreshMaterial: MaterialRefresher? = nil) {
        self.store = store
        self.transport = transport
        self.log = log
        self.limiter = limiter
        self.refreshMaterial = refreshMaterial
    }

    // MARK: Timeline

    public func homeTimeline(_ kind: HomeKind, cursor: String?) async throws -> TimelinePage {
        var v: [String: JSON] = [
            "count": .number(Double(Self.pageSize)),
            "includePromotedContent": false,
            "latestControlAvailable": true,
            "requestContext": cursor == nil ? "launch" : "ptr",
            "withCommunity": true,
            "seenTweetIds": [],
        ]
        if let cursor { v["cursor"] = .string(cursor); v.removeValue(forKey: "requestContext") }
        let op: Operation = kind == .forYou ? .homeTimeline : .homeLatestTimeline
        // The web client POSTs home timelines.
        let json = try await graphQL(op, variables: .object(v), forcePost: true)
        return XParser.timeline(json)
    }

    public func tweetDetail(id: String, cursor: String?) async throws -> ThreadPage {
        var v: [String: JSON] = [
            "focalTweetId": .string(id),
            "with_rux_injections": false,
            "rankingMode": "Relevance",
            "includePromotedContent": false,
            "withCommunity": true,
            "withQuickPromoteEligibilityTweetFields": false,
            "withBirdwatchNotes": true,
            "withVoice": true,
        ]
        if let cursor { v["cursor"] = .string(cursor); v["referrer"] = "tweet" }
        let json = try await graphQL(.tweetDetail, variables: .object(v))
        return XParser.thread(json, focalId: id)
    }

    // MARK: Actions

    public func setLiked(_ liked: Bool, tweetId: String) async throws {
        _ = try await graphQL(liked ? .favoriteTweet : .unfavoriteTweet, variables: ["tweet_id": .string(tweetId)])
    }

    public func setRetweeted(_ retweeted: Bool, tweetId: String) async throws {
        if retweeted {
            _ = try await graphQL(.createRetweet, variables: ["tweet_id": .string(tweetId), "dark_request": false])
        } else {
            _ = try await graphQL(.deleteRetweet, variables: ["source_tweet_id": .string(tweetId), "dark_request": false])
        }
    }

    public func setBookmarked(_ bookmarked: Bool, tweetId: String) async throws {
        _ = try await graphQL(bookmarked ? .createBookmark : .deleteBookmark, variables: ["tweet_id": .string(tweetId)])
    }

    public func createTweet(text: String, replyTo: String?) async throws -> XTweet? {
        var v: [String: JSON] = [
            "tweet_text": .string(text),
            "dark_request": false,
            "media": ["media_entities": [], "possibly_sensitive": false],
            "semantic_annotation_ids": [],
            "disallowed_reply_options": nil,
        ]
        if let replyTo {
            v["reply"] = ["in_reply_to_tweet_id": .string(replyTo), "exclude_reply_user_ids": []]
        }
        let json = try await graphQL(.createTweet, variables: .object(v))
        return XParser.createdTweet(json)
    }

    public func deleteTweet(id: String) async throws {
        _ = try await graphQL(.deleteTweet, variables: ["tweet_id": .string(id), "dark_request": false])
    }

    // MARK: Notifications

    public func notifications(_ kind: NotificationKind, cursor: String?) async throws -> NotificationsPage {
        var v: [String: JSON] = ["timeline_type": .string(kind.rawValue), "count": .number(Double(Self.pageSize))]
        if let cursor { v["cursor"] = .string(cursor) }
        let json = try await graphQL(.notificationsTimeline, variables: .object(v))
        return XParser.notifications(json)
    }

    public func badgeCounts() async throws -> XBadgeCounts {
        let json = try await graphQL(.viewerBadgeCounts, variables: [:])
        return XParser.badgeCounts(json)
    }

    public func markNotificationsSeen(topCursor: String) async throws {
        _ = try await rest("POST", "notifications/all/last_seen_cursor.json", form: ["cursor": topCursor], version: "2")
    }

    // MARK: Users

    public func viewer() async throws -> XUser {
        if let id = await store.credentials?.userId {
            return try await user(id: id)
        }
        let json = try await graphQL(.viewer, variables: ["withCommunitiesMemberships": false])
        guard let u = XParser.userResult(json) else { throw XError.decoding("viewer") }
        return u
    }

    public func user(screenName: String) async throws -> XUser {
        let json = try await graphQL(.userByScreenName, variables: [
            "screen_name": .string(screenName), "withGrokTranslatedBio": false,
        ])
        guard let u = XParser.userResult(json) else { throw XError.decoding("user") }
        return u
    }

    public func user(id: String) async throws -> XUser {
        let json = try await graphQL(.userByRestId, variables: ["userId": .string(id), "withSafetyModeUserFields": true])
        guard let u = XParser.userResult(json) else { throw XError.decoding("user") }
        return u
    }

    public func userTweets(userId: String, includeReplies: Bool, cursor: String?) async throws -> TimelinePage {
        var v: [String: JSON] = [
            "userId": .string(userId),
            "count": .number(Double(Self.pageSize)),
            "includePromotedContent": false,
            "withQuickPromoteEligibilityTweetFields": false,
            "withVoice": true,
        ]
        if includeReplies { v["withCommunity"] = true }
        if let cursor { v["cursor"] = .string(cursor) }
        let json = try await graphQL(includeReplies ? .userTweetsAndReplies : .userTweets, variables: .object(v))
        return XParser.timeline(json)
    }

    public func setFollowing(_ follow: Bool, userId: String) async throws {
        let path = follow ? "friendships/create.json" : "friendships/destroy.json"
        let form = [
            "include_profile_interstitial_type": "1", "include_blocking": "1", "include_blocked_by": "1",
            "include_followed_by": "1", "include_want_retweets": "1", "include_mute_edge": "1",
            "include_can_dm": "1", "include_can_media_tag": "1", "skip_status": "1", "user_id": userId,
        ]
        _ = try await rest("POST", path, form: form)
    }

    // MARK: Search & bookmarks

    public func search(_ query: String, product: SearchProduct, cursor: String?) async throws -> TimelinePage {
        var v: [String: JSON] = [
            "rawQuery": .string(query),
            "count": .number(Double(Self.pageSize)),
            "querySource": "typed_query",
            "product": .string(product.rawValue),
            "withGrokTranslatedBio": false,
        ]
        if let cursor { v["cursor"] = .string(cursor) }
        // SearchTimeline is one of the endpoints that requires a transaction id.
        let json = try await graphQL(.searchTimeline, variables: .object(v))
        return XParser.timeline(json)
    }

    public func bookmarks(cursor: String?) async throws -> TimelinePage {
        var v: [String: JSON] = ["count": .number(Double(Self.pageSize)), "includePromotedContent": false]
        if let cursor { v["cursor"] = .string(cursor) }
        let json = try await graphQL(.bookmarks, variables: .object(v))
        return XParser.timeline(json)
    }

    // MARK: DMs (legacy REST)

    public func dmInbox() async throws -> [DMConversation] {
        let json = try await rest("GET", "dm/inbox_initial_state.json", query: DMParser.inboxQuery)
        return DMParser.inbox(json, viewerId: await store.credentials?.userId)
    }

    public func dmMessages(conversationId: String) async throws -> (messages: [DMMessage], users: [String: XUser]) {
        var q = DMParser.inboxQuery
        q["context"] = "FETCH_DM_CONVERSATION"
        let json = try await rest("GET", "dm/conversation/\(conversationId).json", query: q)
        return DMParser.conversation(json)
    }

    public func sendDM(conversationId: String, text: String) async throws {
        let body: JSON = [
            "conversation_id": .string(conversationId),
            "recipient_ids": false,
            "request_id": .string(UUID().uuidString.lowercased()),
            "text": .string(text),
            "cards_platform": "Web-12",
            "include_cards": 1,
            "include_quote_count": true,
            "dm_users": false,
        ]
        _ = try await rest("POST", "dm/new2.json", query: ["ext": "mediaColor,altText", "include_ext_alt_text": "true"], json: body)
    }

    // MARK: Request plumbing

    public func graphQL(_ op: Operation, variables: JSON, fieldToggles: [String: Bool] = [:], forcePost: Bool = false) async throws -> JSON {
        let config = await store.config
        guard let info = config.info(op) else { throw XError.missingOperation(op.rawValue) }
        guard var url = URL(string: "\(config.graphqlBase)/\(info.queryId)/\(op.rawValue)") else {
            throw XError.missingOperation(op.rawValue)
        }
        let features = config.features(for: op)
        let toggles = config.fieldToggles(for: op, overrides: fieldToggles)
        let post = info.isMutation || forcePost
        var body: Data?
        if post {
            var b: [String: JSON] = ["variables": variables, "queryId": .string(info.queryId)]
            if !features.object.isEmpty { b["features"] = features }
            if let toggles { b["fieldToggles"] = toggles }
            body = JSON.object(b).data()
        } else {
            var items = [("variables", variables.encodedString())]
            if !features.object.isEmpty { items.append(("features", features.encodedString())) }
            if let toggles { items.append(("fieldToggles", toggles.encodedString())) }
            url = url.withStrictQuery(items)
        }
        let json = try await perform(method: post ? "POST" : "GET", url: url, body: body, contentType: "application/json",
                                     bearer: config.bearer, label: op.rawValue)
        let errors = XParser.graphQLErrors(json)
        if !errors.isEmpty, json["data"].object.isEmpty {
            throw XError.graphQL(errors)
        }
        return json
    }

    public func rest(_ method: String, _ path: String, query: [String: String] = [:], form: [String: String]? = nil,
                     json: JSON? = nil, version: String = "1.1") async throws -> JSON {
        let config = await store.config
        guard var url = URL(string: "https://x.com/i/api/\(version)/" + path) else { throw XError.network("bad url") }
        if !query.isEmpty { url = url.withStrictQuery(query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }) }
        var body: Data?
        var contentType: String?
        if let form {
            body = Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\(URL.strictEncode($0.value))" }
                .joined(separator: "&").utf8)
            contentType = "application/x-www-form-urlencoded"
        } else if let json {
            body = json.data()
            contentType = "application/json"
        }
        return try await perform(method: method, url: url, body: body, contentType: contentType, bearer: config.bearer, label: path)
    }

    private func perform(method: String, url: URL, body: Data?, contentType: String?, bearer: String, label: String,
                         attempt: Int = 0) async throws -> JSON {
        try Task.checkCancellation()
        guard let creds = await store.credentials else { throw XError.notLoggedIn }
        try await limiter.acquire()

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue(creds.ct0, forHTTPHeaderField: "x-csrf-token")
        req.setValue("OAuth2Session", forHTTPHeaderField: "x-twitter-auth-type")
        req.setValue("yes", forHTTPHeaderField: "x-twitter-active-user")
        req.setValue("en", forHTTPHeaderField: "x-twitter-client-language")
        req.setValue(creds.cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://x.com/", forHTTPHeaderField: "Referer")
        req.setValue("https://x.com", forHTTPHeaderField: "Origin")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let material = await store.material,
           let tid = try? ClientTransaction.transactionId(method: method, path: url.path, material: material) {
            req.setValue(tid, forHTTPHeaderField: "x-client-transaction-id")
        }

        let start = Date()
        let data: Data
        let resp: HTTPURLResponse
        do {
            (data, resp) = try await transport.send(req)
        } catch {
            await log.record(method: method, url: url, status: nil, durationMs: ms(since: start), note: "\(label): \(error.localizedDescription)")
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw XError.from(error)
        }
        let status = resp.statusCode
        let json = (try? JSON(data: data)) ?? .null
        let errorText = XParser.graphQLErrors(json).joined(separator: "; ")
        await log.record(method: method, url: url, status: status, durationMs: ms(since: start),
                         note: label + (errorText.isEmpty ? "" : " — " + errorText))

        // X rotates ct0 occasionally.
        if let newCt0 = Self.ct0(from: resp), newCt0 != creds.ct0 { await store.updateCt0(newCt0) }

        let reset = (resp.value(forHTTPHeaderField: "x-rate-limit-reset")).flatMap(TimeInterval.init)
        let until = await limiter.didReceive(status: status, resetEpoch: reset)

        switch status {
        case 200..<300:
            return json
        case 401:
            throw XError.unauthorized
        case 403:
            let codes = json["errors"].array.compactMap { $0["code"].int }
            if codes.contains(353), attempt == 0, Self.ct0(from: resp) != nil {
                return try await perform(method: method, url: url, body: body, contentType: contentType, bearer: bearer,
                                         label: label, attempt: attempt + 1)
            }
            throw XError.forbidden(errorText)
        case 404:
            // Often a stale/invalid transaction id; regenerate once, then blame the query ID.
            if attempt == 0, refreshMaterial != nil, (try? await freshMaterial()) != nil {
                return try await perform(method: method, url: url, body: body, contentType: contentType, bearer: bearer,
                                         label: label, attempt: attempt + 1)
            }
            throw XError.notFound
        case 429:
            throw XError.rateLimited(until: until)
        default:
            throw XError.server(status)
        }
    }

    /// Single-flight refresh of the transaction material.
    @discardableResult
    public func freshMaterial() async throws -> TransactionMaterial {
        if let t = refreshingMaterial { return try await t.value }
        guard let refresh = refreshMaterial else { throw XError.network("No transaction material source") }
        let t = Task { try await refresh() }
        refreshingMaterial = t
        defer { refreshingMaterial = nil }
        let m = try await t.value
        await store.setMaterial(m)
        return m
    }

    private func ms(since d: Date) -> Int { Int(Date().timeIntervalSince(d) * 1000) }

    static func ct0(from resp: HTTPURLResponse) -> String? {
        guard let raw = resp.value(forHTTPHeaderField: "Set-Cookie") else { return nil }
        guard let r = raw.range(of: "ct0=") else { return nil }
        let rest = raw[r.upperBound...]
        let value = rest.prefix { $0 != ";" && $0 != "," && $0 != " " }
        return value.isEmpty ? nil : String(value)
    }
}

extension URL {
    static func strictEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    func withStrictQuery(_ items: [(String, String)]) -> URL {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        c.percentEncodedQuery = items.map { "\(URL.strictEncode($0.0))=\(URL.strictEncode($0.1))" }.joined(separator: "&")
        return c.url ?? self
    }
}
