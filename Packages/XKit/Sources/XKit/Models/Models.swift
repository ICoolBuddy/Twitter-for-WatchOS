import Foundation

public struct XUser: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var screenName: String
    public var avatarURL: URL?
    public var bannerURL: URL?
    public var bio: String
    public var location: String
    public var followersCount: Int
    public var followingCount: Int
    public var postsCount: Int
    public var isVerified: Bool
    public var isProtected: Bool
    public var following: Bool
    public var followedBy: Bool
    public var createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id, name, screenName, avatarURL, bannerURL, bio, location
        case followersCount, followingCount, postsCount
        case isVerified, isProtected, following, followedBy, createdAt
    }

    public init(
        id: String, name: String, screenName: String, avatarURL: URL? = nil, bannerURL: URL? = nil,
        bio: String = "", location: String = "", followersCount: Int = 0, followingCount: Int = 0,
        postsCount: Int = 0, isVerified: Bool = false, isProtected: Bool = false, following: Bool = false,
        followedBy: Bool = false, createdAt: Date? = nil
    ) {
        self.id = id; self.name = name; self.screenName = screenName; self.avatarURL = avatarURL
        self.bannerURL = bannerURL; self.bio = bio; self.location = location
        self.followersCount = followersCount; self.followingCount = followingCount
        self.postsCount = postsCount; self.isVerified = isVerified; self.isProtected = isProtected
        self.following = following; self.followedBy = followedBy; self.createdAt = createdAt
    }

    /// Tolerant decode, for **our own persisted JSON** (offline caches, saved posts):
    /// a field added or renamed since the data was written must not make the entry
    /// unreadable. X's live responses never go through Codable (XParser builds the
    /// models), so this cannot hide a parsing bug.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        screenName = (try? c.decode(String.self, forKey: .screenName)) ?? ""
        avatarURL = try? c.decodeIfPresent(URL.self, forKey: .avatarURL)
        bannerURL = try? c.decodeIfPresent(URL.self, forKey: .bannerURL)
        bio = (try? c.decode(String.self, forKey: .bio)) ?? ""
        location = (try? c.decode(String.self, forKey: .location)) ?? ""
        followersCount = (try? c.decode(Int.self, forKey: .followersCount)) ?? 0
        followingCount = (try? c.decode(Int.self, forKey: .followingCount)) ?? 0
        postsCount = (try? c.decode(Int.self, forKey: .postsCount)) ?? 0
        isVerified = (try? c.decode(Bool.self, forKey: .isVerified)) ?? false
        isProtected = (try? c.decode(Bool.self, forKey: .isProtected)) ?? false
        following = (try? c.decode(Bool.self, forKey: .following)) ?? false
        followedBy = (try? c.decode(Bool.self, forKey: .followedBy)) ?? false
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// Small avatar variant (48x48) — X serves `_normal` by default; `_mini` is 24px, `_bigger` 73px.
    public var avatarSmallURL: URL? { avatarURL }
    public var avatarLargeURL: URL? {
        guard let s = avatarURL?.absoluteString else { return nil }
        return URL(string: s.replacingOccurrences(of: "_normal.", with: "_bigger."))
    }
}

public enum XMediaType: String, Codable, Sendable {
    case photo, video, gif = "animated_gif"

    /// X adds media kinds over time. Live parsing degrades unknown kinds to `.photo`
    /// (XParser.media); decoding a cached page must not be stricter, or one new kind makes
    /// the whole cached thread/feed undecodable.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = XMediaType(rawValue: raw) ?? .photo
    }
}

public struct XVideoVariant: Codable, Hashable, Sendable {
    public var url: URL
    public var bitrate: Int?
    public var contentType: String
    public init(url: URL, bitrate: Int?, contentType: String) {
        self.url = url; self.bitrate = bitrate; self.contentType = contentType
    }
}

public struct XMedia: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: XMediaType
    /// Base `https://pbs.twimg.com/media/<id>.jpg` URL without size suffix.
    public var url: URL
    public var width: Int
    public var height: Int
    public var altText: String?
    public var variants: [XVideoVariant]

    public init(id: String, type: XMediaType, url: URL, width: Int, height: Int, altText: String? = nil, variants: [XVideoVariant] = []) {
        self.id = id; self.type = type; self.url = url; self.width = width; self.height = height
        self.altText = altText; self.variants = variants
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, url, width, height, altText, variants
    }

    /// Tolerant decode for persisted JSON (see `XTweet.init(from:)`). Only the URL is
    /// essential; a missing size or kind degrades instead of dropping the attachment.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let url = try? c.decode(URL.self, forKey: .url) else {
            throw DecodingError.keyNotFound(CodingKeys.url, .init(
                codingPath: decoder.codingPath, debugDescription: "media without a url"))
        }
        self.url = url
        id = (try? c.decode(String.self, forKey: .id)) ?? url.absoluteString
        type = (try? c.decode(XMediaType.self, forKey: .type)) ?? .photo
        width = (try? c.decode(Int.self, forKey: .width)) ?? 16
        height = (try? c.decode(Int.self, forKey: .height)) ?? 9
        altText = try? c.decodeIfPresent(String.self, forKey: .altText)
        variants = ((try? c.decode([Failable<XVideoVariant>].self, forKey: .variants)) ?? [])
            .compactMap(\.value)
    }

    /// X image sizes: thumb (150x150 crop), small (680), medium (1200), large (2048).
    public func imageURL(size: String) -> URL {
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = comps?.path ?? ""
        let ext = (path as NSString).pathExtension
        if !ext.isEmpty {
            comps?.path = String(path.dropLast(ext.count + 1))
            comps?.queryItems = [URLQueryItem(name: "format", value: ext), URLQueryItem(name: "name", value: size)]
        } else {
            var items = comps?.queryItems ?? []
            items.removeAll { $0.name == "name" }
            items.append(URLQueryItem(name: "name", value: size))
            comps?.queryItems = items
        }
        return comps?.url ?? url
    }

    public var thumbnailURL: URL { imageURL(size: "small") }

    /// Tiny image (240x240) used as the blurred first pass.
    public var previewURL: URL { imageURL(size: "240x240") }
    /// Feed image (680 px).
    public var feedURL: URL { imageURL(size: "small") }
    /// Full-resolution image (1200 px).
    public var fullURL: URL { imageURL(size: "medium") }

    /// Best MP4 at or below `maxBitrate`; otherwise the lowest-bitrate MP4; otherwise HLS.
    /// Animated GIFs have a single MP4 variant with bitrate 0 and are returned as-is.
    public func playbackURL(maxBitrate: Int = 900_000) -> URL? {
        let mp4 = variants.filter { $0.contentType == "video/mp4" }
        let underCap = mp4.filter { ($0.bitrate ?? 0) <= maxBitrate }
        if let best = underCap.max(by: { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }) {
            return best.url
        }
        if let lowest = mp4.min(by: { ($0.bitrate ?? .max) < ($1.bitrate ?? .max) }) {
            return lowest.url
        }
        return variants.first { $0.contentType == "application/x-mpegURL" }?.url
    }

    /// The lowest bitrate MP4 variant, best suited to the Watch.
    public var lowestBitrateMP4: URL? {
        variants.filter { $0.contentType == "video/mp4" }
            .min { ($0.bitrate ?? .max) < ($1.bitrate ?? .max) }?.url
    }

    public var aspectRatio: Double { height > 0 ? Double(width) / Double(height) : 16.0 / 9.0 }
}

public struct XTweet: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var author: XUser
    public var createdAt: Date?
    public var replyCount: Int
    public var retweetCount: Int
    public var likeCount: Int
    public var quoteCount: Int
    public var bookmarkCount: Int
    public var viewCount: Int?
    public var liked: Bool
    public var retweeted: Bool
    public var bookmarked: Bool
    public var media: [XMedia]
    public var inReplyToScreenName: String?
    public var inReplyToStatusId: String?
    public var conversationId: String?
    /// If this item is a repost, the original post (and `author` is the reposter).
    public var retweetedTweet: XTweetBox?
    public var quotedTweet: XTweetBox?
    /// e.g. "This Post is unavailable." for tombstones.
    public var tombstoneText: String?
    public var lang: String?

    public init(
        id: String, text: String, author: XUser, createdAt: Date? = nil, replyCount: Int = 0,
        retweetCount: Int = 0, likeCount: Int = 0, quoteCount: Int = 0, bookmarkCount: Int = 0,
        viewCount: Int? = nil, liked: Bool = false, retweeted: Bool = false, bookmarked: Bool = false,
        media: [XMedia] = [], inReplyToScreenName: String? = nil, inReplyToStatusId: String? = nil,
        conversationId: String? = nil, retweetedTweet: XTweet? = nil, quotedTweet: XTweet? = nil,
        tombstoneText: String? = nil, lang: String? = nil
    ) {
        self.id = id; self.text = text; self.author = author; self.createdAt = createdAt
        self.replyCount = replyCount; self.retweetCount = retweetCount; self.likeCount = likeCount
        self.quoteCount = quoteCount; self.bookmarkCount = bookmarkCount; self.viewCount = viewCount
        self.liked = liked; self.retweeted = retweeted; self.bookmarked = bookmarked; self.media = media
        self.inReplyToScreenName = inReplyToScreenName; self.inReplyToStatusId = inReplyToStatusId
        self.conversationId = conversationId
        self.retweetedTweet = retweetedTweet.map(XTweetBox.init)
        self.quotedTweet = quotedTweet.map(XTweetBox.init)
        self.tombstoneText = tombstoneText; self.lang = lang
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, author, createdAt, replyCount, retweetCount, likeCount, quoteCount
        case bookmarkCount, viewCount, liked, retweeted, bookmarked, media
        case inReplyToScreenName, inReplyToStatusId, conversationId
        case retweetedTweet, quotedTweet, tombstoneText, lang
    }

    /// Tolerant decode, for **our own persisted JSON** (offline feed/thread caches and
    /// The saved-posts index). A field added since the data was written must not make an
    /// entry unreadable — one missing `bookmarkCount` used to fail the whole entry, and
    /// an unreadable index is what a reader experiences as "my saved posts are gone".
    /// X's live responses never pass through Codable (XParser maps them by hand), so
    /// this cannot hide a parsing bug.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = try? c.decode(String.self, forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(
                codingPath: decoder.codingPath, debugDescription: "post without an id"))
        }
        self.id = id
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        author = (try? c.decode(XUser.self, forKey: .author))
            ?? XUser(id: "", name: "", screenName: "")
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        replyCount = (try? c.decode(Int.self, forKey: .replyCount)) ?? 0
        retweetCount = (try? c.decode(Int.self, forKey: .retweetCount)) ?? 0
        likeCount = (try? c.decode(Int.self, forKey: .likeCount)) ?? 0
        quoteCount = (try? c.decode(Int.self, forKey: .quoteCount)) ?? 0
        bookmarkCount = (try? c.decode(Int.self, forKey: .bookmarkCount)) ?? 0
        viewCount = try? c.decodeIfPresent(Int.self, forKey: .viewCount)
        liked = (try? c.decode(Bool.self, forKey: .liked)) ?? false
        retweeted = (try? c.decode(Bool.self, forKey: .retweeted)) ?? false
        bookmarked = (try? c.decode(Bool.self, forKey: .bookmarked)) ?? false
        // Element-wise: one bad attachment must not cost the other photos.
        let mediaBoxes = (try? c.decode([Failable<XMedia>].self, forKey: .media)) ?? []
        media = mediaBoxes.compactMap(\.value)
        inReplyToScreenName = try? c.decodeIfPresent(String.self, forKey: .inReplyToScreenName)
        inReplyToStatusId = try? c.decodeIfPresent(String.self, forKey: .inReplyToStatusId)
        conversationId = try? c.decodeIfPresent(String.self, forKey: .conversationId)
        retweetedTweet = try? c.decodeIfPresent(XTweetBox.self, forKey: .retweetedTweet)
        quotedTweet = try? c.decodeIfPresent(XTweetBox.self, forKey: .quotedTweet)
        tombstoneText = try? c.decodeIfPresent(String.self, forKey: .tombstoneText)
        lang = try? c.decodeIfPresent(String.self, forKey: .lang)
    }

    /// The post whose content should be displayed (the original for reposts).
    public var displayed: XTweet { retweetedTweet?.value ?? self }
    public var isRetweet: Bool { retweetedTweet != nil }
    public var isTombstone: Bool { tombstoneText != nil }
}

/// Decodes a value as `nil` instead of failing the surrounding array.
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Box to allow recursive value types (repost/quote nesting).
public final class XTweetBox: Codable, Hashable, @unchecked Sendable {
    /// Immutable: that is what makes the `@unchecked Sendable` true (the box is shared).
    public let value: XTweet
    public init(_ value: XTweet) { self.value = value }
    public static func == (l: XTweetBox, r: XTweetBox) -> Bool { l.value == r.value }
    public func hash(into h: inout Hasher) { h.combine(value) }
    public init(from decoder: Decoder) throws { value = try XTweet(from: decoder) }
    public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

public enum TimelineItem: Codable, Hashable, Sendable, Identifiable {
    case tweet(XTweet)
    /// A self-thread / conversation module rendered as consecutive posts.
    case conversation([XTweet])
    case user(XUser)

    public var id: String {
        switch self {
        case .tweet(let t): return "t-" + t.id
        // The chain head, not the whole chain: X re-sends a conversation with more tweets,
        // and the row must keep its identity so a refresh replaces it instead of adding it twice.
        case .conversation(let ts): return "c-" + (ts.first?.id ?? "")
        case .user(let u): return "u-" + u.id
        }
    }

    public var tweets: [XTweet] {
        switch self {
        case .tweet(let t): return [t]
        case .conversation(let ts): return ts
        case .user: return []
        }
    }
}

public struct TimelinePage: Codable, Sendable, Equatable {
    public var items: [TimelineItem]
    public var topCursor: String?
    public var bottomCursor: String?
    /// false when the response had no `instructions` array at all: a schema break, not an
    /// empty timeline. Optional so cached pages from older builds still decode.
    public var instructionsFound: Bool?

    public init(items: [TimelineItem], topCursor: String? = nil, bottomCursor: String? = nil,
                instructionsFound: Bool? = nil) {
        self.items = items; self.topCursor = topCursor; self.bottomCursor = bottomCursor
        self.instructionsFound = instructionsFound
    }

    public var tweets: [XTweet] { items.flatMap(\.tweets) }
}

public struct XNotification: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var icon: String?
    public var date: Date?
    public var users: [XUser]
    public var tweet: XTweet?
    public var isUnread: Bool

    public init(id: String, text: String, icon: String?, date: Date?, users: [XUser], tweet: XTweet?, isUnread: Bool) {
        self.id = id; self.text = text; self.icon = icon; self.date = date; self.users = users
        self.tweet = tweet; self.isUnread = isUnread
    }
}

public struct NotificationsPage: Codable, Sendable, Equatable {
    public var notifications: [XNotification]
    public var topCursor: String?
    public var bottomCursor: String?
    public init(notifications: [XNotification], topCursor: String?, bottomCursor: String?) {
        self.notifications = notifications; self.topCursor = topCursor; self.bottomCursor = bottomCursor
    }
}

public struct ThreadPage: Codable, Sendable, Equatable {
    public var focal: XTweet?
    public var ancestors: [XTweet]
    public var replies: [TimelineItem]
    public var bottomCursor: String?
    public init(focal: XTweet?, ancestors: [XTweet], replies: [TimelineItem], bottomCursor: String?) {
        self.focal = focal; self.ancestors = ancestors; self.replies = replies; self.bottomCursor = bottomCursor
    }
}

public struct XBadgeCounts: Codable, Sendable, Equatable {
    public var notifications: Int
    public var dms: Int
    public init(notifications: Int, dms: Int) { self.notifications = notifications; self.dms = dms }
}

// MARK: DMs (legacy, unencrypted)

public struct DMConversation: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var participants: [XUser]
    public var lastMessage: String?
    public var lastDate: Date?
    public var isEncrypted: Bool
    public var isUnread: Bool
    public init(id: String, participants: [XUser], lastMessage: String?, lastDate: Date?, isEncrypted: Bool, isUnread: Bool) {
        self.id = id; self.participants = participants; self.lastMessage = lastMessage
        self.lastDate = lastDate; self.isEncrypted = isEncrypted; self.isUnread = isUnread
    }
}

public struct DMMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var senderId: String
    public var text: String
    public var date: Date?
    public init(id: String, senderId: String, text: String, date: Date?) {
        self.id = id; self.senderId = senderId; self.text = text; self.date = date
    }
}
