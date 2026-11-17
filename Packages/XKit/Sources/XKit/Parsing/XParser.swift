import Foundation

/// Tolerant parsers for X's GraphQL "URT" (Unified Rich Timeline) responses.
///
/// Shape: `data.<…>.instructions[] → entries[] → content → itemContent → tweet_results.result`.
/// Unknown instruction/entry types (ads, "who to follow", spaces, prompts…) are skipped
/// instead of failing the whole page.
public enum XParser {

    // MARK: Errors embedded in 200 responses

    /// X often returns HTTP 200 with `{"errors":[…]}` and partial/no data.
    public static func graphQLErrors(_ json: JSON) -> [String] {
        json["errors"].array.compactMap { $0["message"].string }
    }

    // MARK: Timeline

    public static func timeline(_ json: JSON) -> TimelinePage {
        let instructions = findInstructions(json["data"]) ?? findInstructions(json) ?? []
        return timeline(instructions: instructions)
    }

    public static func timeline(instructions: [JSON]) -> TimelinePage {
        var items: [TimelineItem] = []
        var top: String?
        var bottom: String?
        var seen = Set<String>()

        func add(_ item: TimelineItem) {
            guard !seen.contains(item.id) else { return }
            seen.insert(item.id)
            items.append(item)
        }

        func handle(entry: JSON) {
            let entryId = entry["entryId"].string ?? ""
            if entryId.hasPrefix("promoted") { return }
            let content = entry["content"]
            let type = content["entryType"].string ?? content["__typename"].string ?? ""
            switch type {
            case "TimelineTimelineItem":
                let ic = content["itemContent"]
                if isCursor(ic) {
                    assignCursor(ic, top: &top, bottom: &bottom)
                } else if let item = timelineItem(from: ic) {
                    add(item)
                }
            case "TimelineTimelineModule":
                var tweets: [XTweet] = []
                for mi in content["items"].array {
                    let ic = mi["item"]["itemContent"]
                    if isCursor(ic) { continue }  // "Show more" cursors inside modules
                    if let item = timelineItem(from: ic) {
                        // Users inside modules are "Who to follow" carousels — skipped.
                        tweets.append(contentsOf: item.tweets)
                    }
                }
                if tweets.count == 1 { add(.tweet(tweets[0])) }
                else if tweets.count > 1 { add(.conversation(tweets)) }
            case "TimelineTimelineCursor":
                assignCursor(content, top: &top, bottom: &bottom)
            default:
                break  // ads, prompts, messages, unknown future types
            }
        }

        for ins in instructions {
            let t = ins["type"].string ?? ins["__typename"].string ?? ""
            switch t {
            case "TimelineAddEntries":
                ins["entries"].array.forEach(handle(entry:))
            case "TimelineReplaceEntry", "TimelinePinEntry":
                handle(entry: ins["entry"])
            case "TimelineAddToModule":
                for mi in ins["moduleItems"].array {
                    if let item = timelineItem(from: mi["item"]["itemContent"]) { add(item) }
                }
            default:
                break
            }
        }
        return TimelinePage(items: items, topCursor: top, bottomCursor: bottom)
    }

    static func isCursor(_ ic: JSON) -> Bool {
        let t = ic["itemType"].string ?? ic["__typename"].string ?? ic["entryType"].string ?? ""
        return t == "TimelineTimelineCursor"
    }

    static func assignCursor(_ c: JSON, top: inout String?, bottom: inout String?) {
        guard let value = c["value"].string else { return }
        switch c["cursorType"].string {
        case "Top": top = value
        case "Bottom": bottom = value
        default: break
        }
    }

    static func timelineItem(from ic: JSON) -> TimelineItem? {
        let t = ic["itemType"].string ?? ic["__typename"].string ?? ""
        if !ic["promotedMetadata"].isNull { return nil }
        switch t {
        case "TimelineTweet":
            return tweet(ic["tweet_results"]["result"]).map(TimelineItem.tweet)
        case "TimelineUser":
            return user(ic["user_results"]["result"]).map(TimelineItem.user)
        default:
            return nil
        }
    }

    /// Recursively finds the first `instructions` array.
    public static func findInstructions(_ json: JSON, depth: Int = 0) -> [JSON]? {
        guard depth < 12 else { return nil }
        switch json {
        case .object(let o):
            if case .array(let a)? = o["instructions"] { return a }
            // Deterministic order so results are stable.
            for k in o.keys.sorted() {
                if let found = findInstructions(o[k]!, depth: depth + 1) { return found }
            }
            return nil
        case .array(let a):
            for v in a { if let found = findInstructions(v, depth: depth + 1) { return found } }
            return nil
        default:
            return nil
        }
    }

    // MARK: Tweet

    public static func tweet(_ raw: JSON, depth: Int = 0) -> XTweet? {
        guard depth < 4 else { return nil }
        var r = raw
        let typename = r["__typename"].string ?? ""
        switch typename {
        case "TweetWithVisibilityResults":
            r = r["tweet"]
        case "TweetTombstone":
            let text = r["tombstone"]["text"]["text"].string ?? "This post is unavailable."
            return XTweet(id: "tombstone-" + Self.stableHash(text), text: "", author: .unknown, tombstoneText: text)
        case "TweetUnavailable":
            return nil
        default:
            if r["legacy"].isNull, !r["tweet"].isNull { r = r["tweet"] }
        }

        let legacy = r["legacy"]
        guard let id = r["rest_id"].string ?? legacy["id_str"].string else { return nil }
        guard let author = user(r["core"]["user_results"]["result"]) else { return nil }

        // Long posts ("note tweets") carry the full text separately.
        let note = r["note_tweet"]["note_tweet_results"]["result"]
        var text: String
        var urls: [JSON]
        if let noteText = note["text"].string {
            text = noteText
            urls = note["entity_set"]["urls"].array
        } else {
            text = legacy["full_text"].string ?? legacy["text"].string ?? ""
            urls = legacy["entities"]["urls"].array
            // Strip leading @mentions of replies using display_text_range.
            let range = legacy["display_text_range"].array.compactMap(\.int)
            if range.count == 2 {
                let scalars = Array(text.unicodeScalars)
                let lo = max(0, min(range[0], scalars.count))
                let hi = max(lo, min(range[1], scalars.count))
                // display_text_range indexes UTF-16-ish code points; scalars are close enough
                // for all realistic posts and we never crash on out-of-range values.
                if lo > 0 || hi < scalars.count {
                    var s = String.UnicodeScalarView()
                    s.append(contentsOf: scalars[lo..<hi])
                    text = String(s)
                }
            }
        }

        let mediaJSON = legacy["extended_entities"]["media"].array.isEmpty
            ? legacy["entities"]["media"].array : legacy["extended_entities"]["media"].array
        let media = mediaJSON.compactMap(XParser.media)
        // Remove t.co links for attached media, expand other t.co links.
        for m in mediaJSON { if let u = m["url"].string { text = text.replacingOccurrences(of: u, with: "") } }
        for u in urls {
            if let short = u["url"].string {
                let display = u["expanded_url"].string ?? u["display_url"].string ?? short
                text = text.replacingOccurrences(of: short, with: display)
            }
        }
        text = decodeEntities(text).trimmingCharacters(in: .whitespacesAndNewlines)

        var retweeted: XTweet?
        let rtRaw = legacy["retweeted_status_result"]["result"]
        if !rtRaw.isNull { retweeted = tweet(rtRaw, depth: depth + 1) }

        var quoted: XTweet?
        let qRaw = r["quoted_status_result"]["result"]
        if !qRaw.isNull { quoted = tweet(qRaw, depth: depth + 1) }

        return XTweet(
            id: id,
            text: text,
            author: author,
            createdAt: parseDate(legacy["created_at"].string),
            replyCount: legacy["reply_count"].int ?? 0,
            retweetCount: legacy["retweet_count"].int ?? 0,
            likeCount: legacy["favorite_count"].int ?? 0,
            quoteCount: legacy["quote_count"].int ?? 0,
            bookmarkCount: legacy["bookmark_count"].int ?? 0,
            viewCount: r["views"]["count"].int,
            liked: legacy["favorited"].bool ?? false,
            retweeted: legacy["retweeted"].bool ?? false,
            bookmarked: legacy["bookmarked"].bool ?? false,
            media: media,
            inReplyToScreenName: legacy["in_reply_to_screen_name"].string,
            inReplyToStatusId: legacy["in_reply_to_status_id_str"].string,
            conversationId: legacy["conversation_id_str"].string,
            retweetedTweet: retweeted,
            quotedTweet: quoted,
            lang: legacy["lang"].string
        )
    }

    static func media(_ m: JSON) -> XMedia? {
        guard let id = m["id_str"].string ?? m["media_key"].string,
              let urlString = m["media_url_https"].string, let url = URL(string: urlString) else { return nil }
        let type = XMediaType(rawValue: m["type"].string ?? "photo") ?? .photo
        let w = m["original_info"]["width"].int ?? m["sizes"]["large"]["w"].int ?? 0
        let h = m["original_info"]["height"].int ?? m["sizes"]["large"]["h"].int ?? 0
        let variants: [XVideoVariant] = m["video_info"]["variants"].array.compactMap { v in
            guard let s = v["url"].string, let u = URL(string: s) else { return nil }
            return XVideoVariant(url: u, bitrate: v["bitrate"].int, contentType: v["content_type"].string ?? "")
        }
        return XMedia(id: id, type: type, url: url, width: w, height: h,
                      altText: m["ext_alt_text"].string, variants: variants)
    }

    // MARK: User

    public static func user(_ raw: JSON) -> XUser? {
        var r = raw
        if r["__typename"].string == "UserUnavailable" { return nil }
        if r["rest_id"].isNull, !r["result"].isNull { r = r["result"] }
        let legacy = r["legacy"]
        guard let id = r["rest_id"].string ?? legacy["id_str"].string else { return nil }
        // Since 2025, name/screen_name/created_at live in `core`, avatar in `avatar`.
        let name = r["core"]["name"].string ?? legacy["name"].string ?? ""
        let screen = r["core"]["screen_name"].string ?? legacy["screen_name"].string ?? ""
        let avatar = r["avatar"]["image_url"].string ?? legacy["profile_image_url_https"].string
        let created = r["core"]["created_at"].string ?? legacy["created_at"].string
        let following = r["relationship_perspectives"]["following"].bool ?? legacy["following"].bool ?? false
        let followedBy = r["relationship_perspectives"]["followed_by"].bool ?? legacy["followed_by"].bool ?? false
        let isProtected = r["privacy"]["protected"].bool ?? legacy["protected"].bool ?? false
        let verified = (r["is_blue_verified"].bool ?? false) || (r["verification"]["verified"].bool ?? false)
            || (legacy["verified"].bool ?? false)
        var bio = r["profile_bio"]["description"].string ?? legacy["description"].string ?? ""
        for u in legacy["entities"]["description"]["urls"].array {
            if let short = u["url"].string { bio = bio.replacingOccurrences(of: short, with: u["expanded_url"].string ?? short) }
        }
        return XUser(
            id: id,
            name: decodeEntities(name),
            screenName: screen,
            avatarURL: avatar.flatMap(URL.init(string:)),
            bannerURL: legacy["profile_banner_url"].string.flatMap { URL(string: $0 + "/600x200") },
            bio: decodeEntities(bio),
            location: r["location"]["location"].string ?? legacy["location"].string ?? "",
            followersCount: legacy["followers_count"].int ?? 0,
            followingCount: legacy["friends_count"].int ?? 0,
            postsCount: legacy["statuses_count"].int ?? 0,
            isVerified: verified,
            isProtected: isProtected,
            following: following,
            followedBy: followedBy,
            createdAt: parseDate(created)
        )
    }

    /// `UserByScreenName` / `UserByRestId` / `Viewer` responses.
    public static func userResult(_ json: JSON) -> XUser? {
        let d = json["data"]
        for candidate in [d["user"]["result"], d["viewer"]["user_results"]["result"], d["user_result"]["result"],
                          d["viewer_v2"]["user_results"]["result"]] {
            if let u = user(candidate) { return u }
        }
        return nil
    }

    // MARK: Thread (TweetDetail)

    public static func thread(_ json: JSON, focalId: String) -> ThreadPage {
        let page = timeline(json)
        var ancestors: [XTweet] = []
        var focal: XTweet?
        var replies: [TimelineItem] = []
        for item in page.items {
            switch item {
            case .tweet(let t):
                if t.id == focalId { focal = t }
                else if focal == nil { ancestors.append(t) }
                else { replies.append(item) }
            case .conversation:
                if focal == nil, let idx = item.tweets.firstIndex(where: { $0.id == focalId }) {
                    ancestors.append(contentsOf: item.tweets[..<idx])
                    focal = item.tweets[idx]
                    let rest = Array(item.tweets[(idx + 1)...])
                    if !rest.isEmpty { replies.append(rest.count == 1 ? .tweet(rest[0]) : .conversation(rest)) }
                } else {
                    replies.append(item)
                }
            case .user:
                break
            }
        }
        return ThreadPage(focal: focal, ancestors: ancestors, replies: replies, bottomCursor: page.bottomCursor)
    }

    // MARK: Notifications (NotificationsTimeline)

    public static func notifications(_ json: JSON) -> NotificationsPage {
        let instructions = findInstructions(json["data"]) ?? []
        var unreadAbove: String?
        var out: [XNotification] = []
        var top: String?, bottom: String?
        var seen = Set<String>()

        func handle(_ entry: JSON) {
            let content = entry["content"]
            let type = content["entryType"].string ?? content["__typename"].string ?? ""
            let sortIndex = entry["sortIndex"].string ?? ""
            if type == "TimelineTimelineCursor" { assignCursor(content, top: &top, bottom: &bottom); return }
            guard type == "TimelineTimelineItem" else { return }
            let ic = content["itemContent"]
            let itemType = ic["itemType"].string ?? ic["__typename"].string ?? ""
            let isUnread = unreadAbove.map { compareSortIndex(sortIndex, $0) > 0 } ?? false
            let id = entry["entryId"].string ?? UUID().uuidString
            guard !seen.contains(id) else { return }
            switch itemType {
            case "TimelineNotification":
                let template = ic["template"]
                let users = template["from_users"].array.compactMap { user($0["user_results"]["result"]) }
                let tweetRef = template["target_objects"].array.first { !$0["tweet_results"].isNull }
                let ms = ic["timestamp_ms"].double
                out.append(XNotification(
                    id: id,
                    text: decodeEntities(ic["rich_message"]["text"].string ?? ic["message"]["text"].string ?? ""),
                    icon: ic["notification_icon"].string,
                    date: ms.map { Date(timeIntervalSince1970: $0 / 1000) },
                    users: users,
                    tweet: tweetRef.flatMap { tweet($0["tweet_results"]["result"]) },
                    isUnread: isUnread))
                seen.insert(id)
            case "TimelineTweet":
                if let t = tweet(ic["tweet_results"]["result"]) {
                    out.append(XNotification(
                        id: id, text: "@\(t.author.screenName) mentioned you", icon: "reply_icon",
                        date: t.createdAt, users: [t.author], tweet: t, isUnread: isUnread))
                    seen.insert(id)
                }
            default:
                break
            }
        }

        for ins in instructions where (ins["type"].string ?? "") == "TimelineMarkEntriesUnreadGreaterThanSortIndex" {
            unreadAbove = ins["sort_index"].string
        }
        for ins in instructions {
            let t = ins["type"].string ?? ""
            if t == "TimelineAddEntries" { ins["entries"].array.forEach(handle) }
            else if t == "TimelineReplaceEntry" { handle(ins["entry"]) }
        }
        return NotificationsPage(notifications: out, topCursor: top, bottomCursor: bottom)
    }

    /// Sort indices are decimal strings that can exceed Int64; compare by length then lexically.
    static func compareSortIndex(_ a: String, _ b: String) -> Int {
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        return a == b ? 0 : (a < b ? -1 : 1)
    }

    // MARK: Badge counts

    /// Works for both `ViewerBadgeCounts` GraphQL and the legacy REST badge_count JSON.
    public static func badgeCounts(_ json: JSON) -> XBadgeCounts {
        var notif = 0, dm = 0
        func walk(_ j: JSON, depth: Int) {
            guard depth < 8 else { return }
            for (k, v) in j.object {
                let key = k.lowercased()
                if let n = v.int {
                    if key.contains("ntab") || key == "notifications" || key.contains("notification") { notif = max(notif, n) }
                    else if key.contains("dm") || key.contains("message") || key.contains("chat") { dm = max(dm, n) }
                } else {
                    walk(v, depth: depth + 1)
                }
            }
        }
        walk(json, depth: 0)
        return XBadgeCounts(notifications: notif, dms: dm)
    }

    // MARK: Created post (CreateTweet)

    public static func createdTweet(_ json: JSON) -> XTweet? {
        tweet(json[path: "data.create_tweet.tweet_results.result"])
            ?? tweet(json[path: "data.notetweet_create.tweet_results.result"])
    }

    // MARK: Helpers

    nonisolated(unsafe) private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return f
    }()
    private static let dateLock = NSLock()

    public static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        dateLock.lock(); defer { dateLock.unlock() }
        return dateFormatter.date(from: s)
    }

    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }

    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

extension XUser {
    public static let unknown = XUser(id: "0", name: "Unavailable", screenName: "unavailable")
}
