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

    /// `instructionsFound == false` means the response had no `instructions` at all: a
    /// schema change, not an empty timeline (callers must not treat it as "no posts").
    public static func timeline(_ json: JSON) -> TimelinePage {
        guard let instructions = findInstructions(json["data"]) ?? findInstructions(json) else {
            return TimelinePage(items: [], instructionsFound: false)
        }
        return timeline(instructions: instructions)
    }

    public static func timeline(instructions: [JSON]) -> TimelinePage {
        var items: [TimelineItem] = []
        var top: String?
        var bottom: String?
        var seen = Set<String>()

        func add(_ item: TimelineItem, entryId: String = "") {
            let item = withEntryIdentity(item, entryId: entryId)
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
                    add(item, entryId: entryId)
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
                if tweets.count == 1 { add(.tweet(tweets[0]), entryId: entryId) }
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
                    if let item = timelineItem(from: mi["item"]["itemContent"]) {
                        add(item, entryId: mi["entryId"].string ?? "")
                    }
                }
            default:
                break
            }
        }
        return TimelinePage(items: items, topCursor: top, bottomCursor: bottom, instructionsFound: true)
    }

    /// Tombstones have no id of their own (it is a hash of the message text, which X sends
    /// identically for every unavailable post), so without the entry id several
    /// "unavailable" rows collapse into one.
    static func withEntryIdentity(_ item: TimelineItem, entryId: String) -> TimelineItem {
        guard case .tweet(var t) = item, t.isTombstone, !entryId.isEmpty else { return item }
        t.id = "tombstone-" + stableHash(t.tombstoneText ?? "") + "-" + stableHash(entryId)
        return .tweet(t)
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

    // MARK: Flat v2 helpers

    /// X's 2026-05 schema moved the contents of `legacy` to the top level of the result
    /// (`legacy` is now `null`). Build one flat dictionary either way: top-level keys win,
    /// missing (or `null`) keys are filled from `legacy` when it is an object.
    static func flatten(_ raw: JSON) -> [String: JSON] {
        var out = raw.object
        for (k, v) in raw["legacy"].object where out[k] == nil || out[k]?.isNull == true {
            out[k] = v
        }
        return out
    }

    /// True for `.null` and empty strings/arrays/objects.
    static func isBlank(_ value: JSON?) -> Bool {
        guard let value else { return true }
        switch value {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        default: return false
        }
    }

    /// Applies a v2 sub-object mapping only when the flat key is missing or empty.
    static func fill(_ flat: inout [String: JSON], _ key: String, _ value: JSON) {
        guard !value.isNull else { return }
        if isBlank(flat[key]) { flat[key] = value }
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

        let f = flatten(r)
        func v(_ key: String) -> JSON { f[key] ?? .null }

        guard let id = r["rest_id"].string ?? v("id_str").string else { return nil }
        guard let author = user(r["core"]["user_results"]["result"]) else { return nil }

        // Long posts ("note tweets") carry the full text separately.
        let note = r["note_tweet"]["note_tweet_results"]["result"]
        var text: String
        var urls: [JSON]
        var alreadyDecoded = false
        if let noteText = note["text"].string {
            // A note's own entity_set can be thin; merging the tweet-level urls is harmless
            // (replacing a t.co that is not in the text is a no-op). Same union as twscrape.
            urls = note["entity_set"]["urls"].array + v("entities")["urls"].array
            // Note results carry no display_text_range: strip a long reply's leading
            // mentions the way display_text_range does for short ones.
            text = stripLeadingReplyMentions(noteText, entitySet: note["entity_set"],
                                             inReplyTo: v("in_reply_to_screen_name").string)
        } else {
            // Decode HTML entities *before* slicing: X escapes `&`, `<`, `>` in
            // `full_text`, and slicing the longer escaped string with
            // `display_text_range` could cut real characters off the end. With the
            // decoded (shorter) text the worst case is keeping a trailing media
            // link, which is removed below anyway.
            text = decodeEntities(v("full_text").string ?? v("text").string ?? "")
            alreadyDecoded = true
            urls = v("entities")["urls"].array
            // Strip leading @mentions of replies using display_text_range.
            let range = v("display_text_range").array.compactMap(\.int)
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

        var retweeted: XTweet?
        let rtRaw = v("retweeted_status_result")["result"]
        if !rtRaw.isNull { retweeted = tweet(rtRaw, depth: depth + 1) }

        var quoted: XTweet?
        let qRaw = r["quoted_status_result"]["result"]
        if !qRaw.isNull { quoted = tweet(qRaw, depth: depth + 1) }

        let mediaJSON = v("extended_entities")["media"].array.isEmpty
            ? v("entities")["media"].array : v("extended_entities")["media"].array
        let media = mediaJSON.compactMap(XParser.media)
        // Remove t.co links for attached media, expand other t.co links.
        for m in mediaJSON { if let u = m["url"].string { text = text.replacingOccurrences(of: u, with: "") } }
        // The quoted post is shown as a card, so its permalink is noise in the text.
        let quotePermalink = v("quoted_status_permalink")["url"].string
        for u in urls {
            if let short = u["url"].string {
                let display = u["expanded_url"].string ?? u["display_url"].string ?? short
                let isQuoteLink = quoted != nil
                    && (short == quotePermalink || isStatusLink(display, id: quoted?.id))
                text = text.replacingOccurrences(of: short, with: isQuoteLink ? "" : display)
            }
        }
        if quoted != nil, let quotePermalink {
            text = text.replacingOccurrences(of: quotePermalink, with: "")
        }
        if !alreadyDecoded { text = decodeEntities(text) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        return XTweet(
            id: id,
            text: text,
            author: author,
            createdAt: parseDate(v("created_at").string),
            replyCount: v("reply_count").int ?? 0,
            retweetCount: v("retweet_count").int ?? 0,
            likeCount: v("favorite_count").int ?? 0,
            quoteCount: v("quote_count").int ?? 0,
            bookmarkCount: v("bookmark_count").int ?? 0,
            viewCount: r["views"]["count"].int,
            liked: v("favorited").bool ?? false,
            retweeted: v("retweeted").bool ?? false,
            bookmarked: v("bookmarked").bool ?? false,
            media: media,
            inReplyToScreenName: v("in_reply_to_screen_name").string,
            inReplyToStatusId: v("in_reply_to_status_id_str").string,
            conversationId: v("conversation_id_str").string,
            retweetedTweet: retweeted,
            quotedTweet: quoted,
            lang: v("lang").string
        )
    }

    /// `https://x.com/<user>/status/<id>` (or twitter.com, with query/suffix).
    static func isStatusLink(_ url: String, id: String?) -> Bool {
        guard let id, !id.isEmpty else { return false }
        let lower = url.lowercased()
        guard lower.contains("twitter.com/") || lower.contains("x.com/") else { return false }
        return lower.contains("/status/" + id)
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

        var f = flatten(r)
        // 2026-05 schema: user fields moved into typed sub-objects.
        fill(&f, "screen_name", r["core"]["screen_name"])
        fill(&f, "name", r["core"]["name"])
        fill(&f, "created_at", r["core"]["created_at"])
        fill(&f, "profile_image_url_https", r["avatar"]["image_url"])
        fill(&f, "profile_banner_url", r["banner"]["image_url"])
        // `location` is the one field whose v2 sub-object is also called `location`:
        // the flat key holds the sub-object, so only use it when there is no flat string.
        if let loc = r["location"]["location"].string, f["location"]?.string == nil {
            f["location"] = .string(loc)
        }
        fill(&f, "protected", r["privacy"]["protected"])
        fill(&f, "verified", r["verification"]["verified"])
        fill(&f, "description", r["profile_bio"]["description"])
        fill(&f, "followers_count", r["relationship_counts"]["followers"])
        fill(&f, "friends_count", r["relationship_counts"]["following"])
        fill(&f, "statuses_count", r["tweet_counts"]["tweets"])
        fill(&f, "media_tweets_count", r["tweet_counts"]["media_tweets"])
        fill(&f, "favourites_count", r["action_counts"]["favorites_count"])

        func v(_ key: String) -> JSON { f[key] ?? .null }

        guard let id = r["rest_id"].string ?? v("id_str").string else { return nil }
        let name = v("name").string ?? ""
        let screen = v("screen_name").string ?? ""
        let following = r["relationship_perspectives"]["following"].bool ?? v("following").bool ?? false
        let followedBy = r["relationship_perspectives"]["followed_by"].bool ?? v("followed_by").bool ?? false
        let isProtected = v("protected").bool ?? false
        let verifiedType = r["verification"]["verified_type"].string
        let verified = (r["is_blue_verified"].bool ?? false) || (v("verified").bool ?? false)
            || (r["verification"]["verified"].bool ?? false)
            || (verifiedType != nil && verifiedType != "none")
        var bio = v("description").string ?? ""
        var bioURLs = r["profile_bio"]["entities"]["urls"].array
        if bioURLs.isEmpty { bioURLs = v("entities")["description"]["urls"].array }
        for u in bioURLs {
            if let short = u["url"].string {
                bio = bio.replacingOccurrences(of: short, with: u["expanded_url"].string ?? short)
            }
        }
        // `banner.image_url` is already a complete image URL (append nothing); the legacy
        // `profile_banner_url` is a base path that needs a size suffix.
        let banner: URL?
        if let b = r["banner"]["image_url"].string {
            banner = URL(string: b)
        } else if let b = v("profile_banner_url").string {
            banner = URL(string: b + "/600x200")
        } else {
            banner = nil
        }
        return XUser(
            id: id,
            name: decodeEntities(name),
            screenName: screen,
            avatarURL: v("profile_image_url_https").string.flatMap(URL.init(string:)),
            bannerURL: banner,
            bio: decodeEntities(bio),
            location: v("location").string ?? "",
            followersCount: v("followers_count").int ?? 0,
            followingCount: v("friends_count").int ?? 0,
            postsCount: v("statuses_count").int ?? 0,
            isVerified: verified,
            isProtected: isProtected,
            following: following,
            followedBy: followedBy,
            createdAt: parseDate(v("created_at").string)
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

    /// Real replies are the items whose **first** tweet directly replies to the focal post
    /// (`in_reply_to_status_id_str == focalId`); a conversation module keeps its whole chain
    /// when its first tweet qualifies. "Discover more" recommendations (entry ids starting
    /// `tweetdetailrelatedtweets`) and unrelated conversations are dropped.
    public static func thread(_ json: JSON, focalId: String) -> ThreadPage {
        let instructions = findInstructions(json["data"]) ?? findInstructions(json) ?? []
        var ancestors: [XTweet] = []
        var focal: XTweet?
        var replies: [TimelineItem] = []
        var cursors: [String: String] = [:]          // entry level: the page cursor
        var moduleCursors: [String: String] = [:]    // inside a conversation module: fallback
        var seen = Set<String>()

        func takeCursor(_ c: JSON, fallback: Bool = false) {
            guard let kind = c["cursorType"].string, let value = c["value"].string, !value.isEmpty else { return }
            if fallback {
                if moduleCursors[kind] == nil { moduleCursors[kind] = value }
            } else if cursors[kind] == nil {
                cursors[kind] = value
            }
        }

        func consume(_ item: TimelineItem, entryId: String = "") {
            let item = withEntryIdentity(item, entryId: entryId)
            guard seen.insert(item.id).inserted else { return }
            if focal == nil, item.tweets.contains(where: { $0.id == focalId }) {
                if case .conversation(let chain) = item,
                   let idx = chain.firstIndex(where: { $0.id == focalId }) {
                    ancestors.append(contentsOf: chain[..<idx])
                    focal = chain[idx]
                    let rest = Array(chain[(idx + 1)...])
                    if !rest.isEmpty, rest[0].inReplyToStatusId == focalId {
                        replies.append(rest.count == 1 ? .tweet(rest[0]) : .conversation(rest))
                    }
                } else if case .tweet(let t) = item {
                    focal = t
                }
                return
            }
            if item.tweets.first?.inReplyToStatusId == focalId {
                replies.append(item)
                return
            }
            // The ancestor chain precedes the focal post; anything else is not a reply.
            if focal == nil { ancestors.append(contentsOf: item.tweets) }
        }

        func handle(entry: JSON) {
            let entryId = entry["entryId"].string ?? ""
            if entryId.hasPrefix("tweetdetailrelatedtweets") { return }
            let content = entry["content"]
            let type = content["entryType"].string ?? content["__typename"].string ?? ""
            switch type {
            case "TimelineTimelineItem":
                let ic = content["itemContent"]
                if isCursor(ic) {
                    takeCursor(ic)
                } else if let item = timelineItem(from: ic) {
                    consume(item, entryId: entryId)
                }
            case "TimelineTimelineModule":
                var tweets: [XTweet] = []
                for mi in content["items"].array {
                    let ic = mi["item"]["itemContent"]
                    // A cursor inside a module belongs to that conversation ("show more
                    // replies in this thread"): only a fallback page cursor.
                    if isCursor(ic) { takeCursor(ic, fallback: true); continue }
                    if let item = timelineItem(from: ic) { tweets.append(contentsOf: item.tweets) }
                }
                if tweets.count == 1 { consume(.tweet(tweets[0]), entryId: entryId) }
                else if tweets.count > 1 { consume(.conversation(tweets)) }
            case "TimelineTimelineCursor":
                takeCursor(content)
            default:
                break
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
                    let ic = mi["item"]["itemContent"]
                    if isCursor(ic) { takeCursor(ic, fallback: true); continue }
                    if let item = timelineItem(from: ic) { consume(item, entryId: mi["entryId"].string ?? "") }
                }
            default:
                break
            }
        }

        // Reply pagination: the page cursor is the one X puts at entry level
        // (ShowMoreThreads, then ShowMoreThreadsPrompt, then Bottom; twikit pages this way).
        // A module's own cursor is used only when the page has none (twscrape finds a
        // ShowMoreThreads cursor anywhere in the response).
        let order = ["ShowMoreThreads", "ShowMoreThreadsPrompt", "Bottom"]
        let bottom = order.lazy.compactMap { cursors[$0] }.first
            ?? order.lazy.compactMap { moduleCursors[$0] }.first
        // The same ancestor can arrive standalone and inside a module (different item ids).
        var seenAncestors = Set<String>()
        ancestors = ancestors.filter { seenAncestors.insert($0.id).inserted }
        return ThreadPage(focal: focal, ancestors: ancestors, replies: replies, bottomCursor: bottom)
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
            // A random fallback id would change on every refresh (no dedupe, rows rebuilt).
            let id = entry["entryId"].string ?? ic["id"].string ?? UUID().uuidString
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
        // Exact names first (ViewerBadgeCounts and the REST badge_count both use them); the
        // substring heuristic stays as a fallback for unknown shapes. Arrays are walked too.
        let notifKeys: Set<String> = ["ntab_unread_count", "notifications", "notification_count",
                                      "unread_notification_count"]
        let dmKeys: Set<String> = ["dm_unread_count", "dms", "unread_dm_count", "messages"]
        var notif = 0, dm = 0
        func walk(_ j: JSON, depth: Int) {
            guard depth < 8 else { return }
            if case .array(let a) = j {
                for x in a { walk(x, depth: depth + 1) }
                return
            }
            for (k, v) in j.object {
                let key = k.lowercased()
                if let n = v.int {
                    if notifKeys.contains(key) { notif = max(notif, n) }
                    else if dmKeys.contains(key) { dm = max(dm, n) }
                    else if key.contains("ntab") || key.contains("notification") { notif = max(notif, n) }
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

    /// Cuts the leading `@mention`s of a long reply the way `display_text_range` does for a
    /// short one: only while they start at the cursor *and* the first is the reply target,
    /// using the note's own mention indices. A post that merely starts with a mention keeps it.
    static func stripLeadingReplyMentions(_ text: String, entitySet: JSON, inReplyTo: String?) -> String {
        guard let replyTo = inReplyTo?.lowercased(), !replyTo.isEmpty else { return text }
        let mentions: [(name: String, start: Int, end: Int)] = entitySet["user_mentions"].array.compactMap { m in
            guard let name = m["screen_name"].string else { return nil }
            let idx = m["indices"].array.compactMap(\.int)
            guard idx.count == 2, idx[0] >= 0, idx[1] > idx[0] else { return nil }
            return (name.lowercased(), idx[0], idx[1])
        }.sorted { $0.start < $1.start }

        let scalars = Array(text.unicodeScalars)
        var cut = 0
        var stripped = false
        for m in mentions where m.start == cut {
            if !stripped, m.name != replyTo { return text }
            stripped = true
            cut = min(m.end, scalars.count)
            while cut < scalars.count, scalars[cut].value == 32 { cut += 1 }
        }
        guard stripped, cut > 0 else { return text }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[cut...])
        return String(out)
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
