import Foundation

/// GraphQL operations Perch uses.
public enum Operation: String, CaseIterable, Codable, Sendable {
    case homeTimeline = "HomeTimeline"
    case homeLatestTimeline = "HomeLatestTimeline"
    case tweetDetail = "TweetDetail"
    case tweetResultByRestId = "TweetResultByRestId"
    case createTweet = "CreateTweet"
    case deleteTweet = "DeleteTweet"
    case favoriteTweet = "FavoriteTweet"
    case unfavoriteTweet = "UnfavoriteTweet"
    case createRetweet = "CreateRetweet"
    case deleteRetweet = "DeleteRetweet"
    case createBookmark = "CreateBookmark"
    case deleteBookmark = "DeleteBookmark"
    case bookmarks = "Bookmarks"
    case likes = "Likes"
    case userByScreenName = "UserByScreenName"
    case userByRestId = "UserByRestId"
    case userTweets = "UserTweets"
    case userTweetsAndReplies = "UserTweetsAndReplies"
    case searchTimeline = "SearchTimeline"
    case notificationsTimeline = "NotificationsTimeline"
    case viewer = "Viewer"
    case viewerBadgeCounts = "ViewerBadgeCounts"
}

public struct OperationInfo: Codable, Sendable, Equatable {
    public var queryId: String
    public var type: String
    public var features: [String]
    public var fieldToggles: [String]

    public init(queryId: String, type: String, features: [String], fieldToggles: [String]) {
        self.queryId = queryId; self.type = type; self.features = features; self.fieldToggles = fieldToggles
    }

    public var isMutation: Bool { type == "mutation" }
}

public struct SignerInfo: Codable, Sendable, Equatable {
    public var indices: [Int]
    public var source: String
    public init(indices: [Int], source: String) { self.indices = indices; self.source = source }
}

/// Mirrors `endpoints.json`. Bundled as a fallback, refreshed at runtime by
/// scraping x.com's JS (iPhone) or from an optional remote override URL.
public struct EndpointConfig: Codable, Sendable, Equatable {
    public var version: Int
    public var updatedAt: String
    public var bearer: String
    public var graphqlBase: String
    public var operations: [String: OperationInfo]
    public var featureValues: [String: Bool]
    public var signer: SignerInfo?
    public var legacySigner: SignerInfo?

    public init(version: Int = 1, updatedAt: String, bearer: String, graphqlBase: String,
                operations: [String: OperationInfo], featureValues: [String: Bool],
                signer: SignerInfo?, legacySigner: SignerInfo?) {
        self.version = version; self.updatedAt = updatedAt; self.bearer = bearer; self.graphqlBase = graphqlBase
        self.operations = operations; self.featureValues = featureValues
        self.signer = signer; self.legacySigner = legacySigner
    }

    public static let publicBearer =
        "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"

    public func info(_ op: Operation) -> OperationInfo? { operations[op.rawValue] }

    /// `features` query/body param for an operation: every switch the op
    /// declares, with the web client's default value (false if unknown).
    public func features(for op: Operation) -> JSON {
        var out: [String: JSON] = [:]
        for f in info(op)?.features ?? [] { out[f] = .bool(featureValues[f] ?? false) }
        return .object(out)
    }

    public func fieldToggles(for op: Operation, overrides: [String: Bool] = [:]) -> JSON? {
        guard let toggles = info(op)?.fieldToggles, !toggles.isEmpty else { return nil }
        var out: [String: JSON] = [:]
        for t in toggles { out[t] = .bool(overrides[t] ?? false) }
        return .object(out)
    }

    /// Merges a newer (possibly partial) config on top of this one. Operations
    /// missing from `newer` keep their current values.
    public func merging(_ newer: EndpointConfig) -> EndpointConfig {
        var c = self
        c.version = newer.version
        c.updatedAt = newer.updatedAt
        if !newer.bearer.isEmpty { c.bearer = newer.bearer }
        // The base URL decides where the session Cookie and ct0 are sent: a remote
        // override (or a corrupted file) must never be able to move it off x.com.
        if !newer.graphqlBase.isEmpty, EndpointConfig.isAllowedGraphQLBase(newer.graphqlBase) {
            c.graphqlBase = newer.graphqlBase
        }
        c.operations.merge(newer.operations) { _, new in new }
        c.featureValues.merge(newer.featureValues) { _, new in new }
        if let s = newer.signer, !s.indices.isEmpty { c.signer = s }
        if let s = newer.legacySigner, !s.indices.isEmpty { c.legacySigner = s }
        return c
    }

    /// The only hosts that may receive a request carrying the account's Cookie/ct0.
    public static func isAllowedGraphQLBase(_ raw: String) -> Bool {
        guard let u = URL(string: raw), u.scheme?.lowercased() == "https",
              let host = u.host?.lowercased() else { return false }
        return host == "x.com" || host == "api.x.com"
    }

    public static func decode(_ data: Data) throws -> EndpointConfig {
        try JSONDecoder().decode(EndpointConfig.self, from: data)
    }

    public func encoded() -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)) ?? Data()
    }

    /// The fallback shipped inside XKit.
    public static let bundled: EndpointConfig = {
        if let url = Bundle.module.url(forResource: "endpoints", withExtension: "json"),
           let data = try? Data(contentsOf: url), let cfg = try? decode(data) {
            return cfg
        }
        return EndpointConfig(updatedAt: "", bearer: publicBearer, graphqlBase: "https://x.com/i/api/graphql",
                              operations: [:], featureValues: [:],
                              signer: SignerInfo(indices: [35, 42, 37, 10], source: "x-web"), legacySigner: nil)
    }()
}
