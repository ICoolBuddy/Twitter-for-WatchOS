import Foundation

/// Parser for the legacy (unencrypted) DM REST API (`/i/api/1.1/dm/*`).
/// End-to-end encrypted "Chat" conversations are not readable here; they are
/// flagged `isEncrypted` so the UI can say "Open on iPhone".
public enum DMParser {
    public static let inboxQuery: [String: String] = [
        "nsfw_filtering_enabled": "false",
        "filter_low_quality": "true",
        "include_quality": "all",
        "dm_users": "true",
        "include_groups": "true",
        "include_inbox_timelines": "true",
        "include_conversation_info": "true",
        "dm_secret_conversations_enabled": "false",
        "krs_registration_enabled": "false",
        "cards_platform": "Web-12",
        "include_cards": "1",
        "include_ext_alt_text": "true",
        "supports_reactions": "true",
        "ext": "mediaColor,altText",
        "count": "30",
    ]

    static func users(_ j: JSON) -> [String: XUser] {
        var out: [String: XUser] = [:]
        for (id, u) in j.object {
            out[id] = XUser(
                id: u["id_str"].string ?? id,
                name: XParser.decodeEntities(u["name"].string ?? ""),
                screenName: u["screen_name"].string ?? "",
                avatarURL: u["profile_image_url_https"].string.flatMap(URL.init(string:)),
                isVerified: u["is_blue_verified"].bool ?? u["verified"].bool ?? false,
                isProtected: u["protected"].bool ?? false)
        }
        return out
    }

    static func message(_ entry: JSON) -> DMMessage? {
        let m = entry["message"]
        guard !m.isNull else { return nil }
        let d = m["message_data"]
        guard let id = d["id"].string ?? m["id"].string else { return nil }
        var text = d["text"].string ?? ""
        for u in d["entities"]["urls"].array {
            if let short = u["url"].string { text = text.replacingOccurrences(of: short, with: u["expanded_url"].string ?? short) }
        }
        if let att = d["attachment"].object.keys.first, text.isEmpty { text = "[\(att)]" }
        let ms = d["time"].double ?? m["time"].double
        return DMMessage(id: id, senderId: d["sender_id"].string ?? "", text: XParser.decodeEntities(text),
                         date: ms.map { Date(timeIntervalSince1970: $0 / 1000) })
    }

    public static func inbox(_ json: JSON, viewerId: String?) -> [DMConversation] {
        let root = json["inbox_initial_state"].isNull ? json["user_events"] : json["inbox_initial_state"]
        let users = users(root["users"])
        var lastByConv: [String: DMMessage] = [:]
        for e in root["entries"].array {
            guard let msg = message(e), let cid = e["message"]["conversation_id"].string else { continue }
            if let existing = lastByConv[cid], XParser.compareSortIndex(existing.id, msg.id) >= 0 { continue }
            lastByConv[cid] = msg
        }
        var out: [DMConversation] = []
        for (cid, c) in root["conversations"].object {
            let type = c["type"].string ?? ""
            let participants = c["participants"].array.compactMap { $0["user_id"].string }
                .filter { $0 != viewerId }.compactMap { users[$0] }
            let encrypted = type.uppercased().contains("SECRET") || (c["is_encrypted"].bool ?? false)
                || (c["encrypted"].bool ?? false)
            let lastRead = c["last_read_event_id"].string ?? "0"
            let maxEntry = c["max_entry_id"].string ?? lastRead
            let sortMs = c["sort_timestamp"].double
            out.append(DMConversation(
                id: cid,
                participants: participants,
                lastMessage: lastByConv[cid]?.text,
                lastDate: lastByConv[cid]?.date ?? sortMs.map { Date(timeIntervalSince1970: $0 / 1000) },
                isEncrypted: encrypted,
                isUnread: XParser.compareSortIndex(maxEntry, lastRead) > 0))
        }
        return out.sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    public static func conversation(_ json: JSON) -> (messages: [DMMessage], users: [String: XUser]) {
        let root = json["conversation_timeline"]
        let msgs = root["entries"].array.compactMap(message)
            .sorted { XParser.compareSortIndex($0.id, $1.id) < 0 }
        return (msgs, users(root["users"]))
    }
}
