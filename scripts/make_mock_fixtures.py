#!/usr/bin/env python3
"""
Generates anonymized, structurally realistic X GraphQL responses used by
XKit's parser tests and the apps' Demo mode. All users/posts are fictional.

  python3 scripts/make_mock_fixtures.py
"""
import json
import os

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "Packages/XKit/Sources/XKit/Resources/Mock")
AVATAR = "https://abs.twimg.com/sticky/default_profile_images/default_profile_normal.png"


def user(uid, name, handle, new_shape=True, following=False, verified=False, bio="", followers=120):
    legacy = {
        "description": bio, "followers_count": followers, "friends_count": 80, "statuses_count": 999,
        "entities": {"description": {"urls": []}}, "location": "Somewhere",
    }
    u = {"__typename": "User", "id": "VXNlcjo" + uid, "rest_id": uid, "is_blue_verified": verified, "legacy": legacy}
    if new_shape:
        u["core"] = {"name": name, "screen_name": handle, "created_at": "Tue Mar 21 20:50:14 +0000 2006"}
        u["avatar"] = {"image_url": AVATAR}
        u["relationship_perspectives"] = {"following": following}
        u["privacy"] = {"protected": False}
    else:
        legacy.update({"name": name, "screen_name": handle, "profile_image_url_https": AVATAR,
                       "following": following, "created_at": "Tue Mar 21 20:50:14 +0000 2006"})
    return u


def tweet(tid, u, text, likes=3, rts=1, replies=0, media=None, rt=None, quote=None, liked=False,
          reply_to=None, conv=None, created="Mon Nov 16 18:30:00 +0000 2026", urls=None):
    legacy = {
        "id_str": tid, "full_text": text, "created_at": created, "favorite_count": likes,
        "retweet_count": rts, "reply_count": replies, "quote_count": 0, "bookmark_count": 0,
        "favorited": liked, "retweeted": False, "bookmarked": False, "lang": "en",
        "conversation_id_str": conv or tid, "user_id_str": u["rest_id"],
        "display_text_range": [0, len(text)],
        "entities": {"hashtags": [], "symbols": [], "user_mentions": [], "urls": urls or []},
    }
    if reply_to:
        legacy["in_reply_to_status_id_str"] = reply_to[0]
        legacy["in_reply_to_screen_name"] = reply_to[1]
    if media:
        legacy["entities"]["media"] = media
        legacy["extended_entities"] = {"media": media}
    if rt:
        legacy["retweeted_status_result"] = {"result": rt}
    t = {"__typename": "Tweet", "rest_id": tid, "core": {"user_results": {"result": u}},
         "views": {"count": str(likes * 40), "state": "EnabledWithCount"}, "legacy": legacy,
         "edit_control": {"edit_tweet_ids": [tid], "is_edit_eligible": False}}
    if quote:
        t["quoted_status_result"] = {"result": quote}
        legacy["is_quote_status"] = True
    return t


def photo(mid, short="https://t.co/AbCdEf123", w=1200, h=800):
    return {"id_str": mid, "media_key": "3_" + mid, "type": "photo", "url": short,
            "display_url": "pic.x.com/AbCdEf123", "expanded_url": "https://x.com/i/status/1/photo/1",
            "media_url_https": f"https://pbs.twimg.com/media/Mock{mid}.jpg",
            "original_info": {"width": w, "height": h}, "ext_alt_text": "A mock photo",
            "sizes": {"large": {"w": w, "h": h, "resize": "fit"}}}


def video(mid):
    m = photo(mid, "https://t.co/VidEo999", 1280, 720)
    m["type"] = "video"
    m["media_url_https"] = f"https://pbs.twimg.com/ext_tw_video_thumb/{mid}/pu/img/thumb.jpg"
    m["video_info"] = {"aspect_ratio": [16, 9], "duration_millis": 12000, "variants": [
        {"content_type": "application/x-mpegURL", "url": "https://video.twimg.com/ext_tw_video/1/pu/pl/x.m3u8"},
        {"bitrate": 2176000, "content_type": "video/mp4", "url": "https://video.twimg.com/ext_tw_video/1/pu/vid/1280x720/hi.mp4"},
        {"bitrate": 256000, "content_type": "video/mp4", "url": "https://video.twimg.com/ext_tw_video/1/pu/vid/480x270/lo.mp4"},
    ]}
    return m


def item(entry_id, result, sort):
    return {"entryId": entry_id, "sortIndex": sort, "content": {
        "entryType": "TimelineTimelineItem", "__typename": "TimelineTimelineItem",
        "itemContent": {"itemType": "TimelineTweet", "__typename": "TimelineTweet",
                        "tweet_results": {"result": result}, "tweetDisplayType": "Tweet"}}}


def user_item(entry_id, u, sort):
    return {"entryId": entry_id, "sortIndex": sort, "content": {
        "entryType": "TimelineTimelineItem", "__typename": "TimelineTimelineItem",
        "itemContent": {"itemType": "TimelineUser", "__typename": "TimelineUser",
                        "user_results": {"result": u}, "userDisplayType": "User"}}}


def cursor(kind, value, sort):
    return {"entryId": f"cursor-{kind.lower()}-{sort}", "sortIndex": sort, "content": {
        "entryType": "TimelineTimelineCursor", "__typename": "TimelineTimelineCursor",
        "value": value, "cursorType": kind}}


def module(entry_id, items, sort, display="VerticalConversation"):
    return {"entryId": entry_id, "sortIndex": sort, "content": {
        "entryType": "TimelineTimelineModule", "__typename": "TimelineTimelineModule",
        "displayType": display, "items": items}}


def module_item(entry_id, result=None, u=None):
    if u is not None:
        ic = {"itemType": "TimelineUser", "__typename": "TimelineUser", "user_results": {"result": u}}
    else:
        ic = {"itemType": "TimelineTweet", "__typename": "TimelineTweet", "tweet_results": {"result": result}}
    return {"entryId": entry_id, "item": {"itemContent": ic}}


ada = user("1001", "Ada Example", "ada_example", verified=True, bio="Writes about engines. https://t.co/Bio1",
           followers=5400)
ada["legacy"]["entities"]["description"]["urls"] = [{"url": "https://t.co/Bio1", "expanded_url": "https://example.com"}]
ben = user("1002", "Ben Sample", "bensample", new_shape=False, following=True)
cleo = user("1003", "Cleo &amp; Co", "cleo_co")
dev = user("1004", "Dev Placeholder", "devplace", following=True)
me = user("2000", "Perch Tester", "perch_tester", followers=42)


def home():
    t1 = tweet("1860000000000000001", ada, "Hello from a mock timeline! Read more https://t.co/Link1 https://t.co/AbCdEf123",
               likes=42, rts=7, replies=3, media=[photo("700001")],
               urls=[{"url": "https://t.co/Link1", "expanded_url": "https://example.com/post", "display_url": "example.com/post"}])
    t2_inner = tweet("1860000000000000002", ben, "Visibility-wrapped post &amp; entities &lt;3", likes=5, liked=True)
    t2 = {"__typename": "TweetWithVisibilityResults", "tweet": t2_inner,
          "limitedActionResults": {"limited_actions": [{"action": "Reply"}]}}
    orig = tweet("1860000000000000003", cleo, "Original post that gets reposted.", likes=900, rts=120,
                 media=[video("700003")])
    rt = tweet("1860000000000000004", dev, "RT @cleo_co: Original post that gets reposted.", likes=0, rts=120, rt=orig)
    q_inner = tweet("1860000000000000005", ada, "I am the quoted post.", likes=10)
    quote = tweet("1860000000000000006", cleo, "Quoting this one:", quote=q_inner, likes=2)
    promoted = item("promoted-tweet-1860000000000000099-abc", tweet("1860000000000000099", dev, "Buy things!"), "1860000000000000099")
    promoted["content"]["itemContent"]["promotedMetadata"] = {"advertiser_results": {}}
    conv_a = tweet("1860000000000000007", ben, "Thread start 1/2", conv="1860000000000000007")
    conv_b = tweet("1860000000000000008", ben, "@bensample Thread part 2/2", conv="1860000000000000007",
                   reply_to=("1860000000000000007", "bensample"))
    conv_b["legacy"]["display_text_range"] = [11, len(conv_b["legacy"]["full_text"])]
    tomb = {"__typename": "TweetTombstone", "tombstone": {"__typename": "TextTombstone",
            "text": {"rtl": False, "text": "This Post is from an account that no longer exists.", "entities": []}}}
    entries = [
        item("tweet-1860000000000000001", t1, "1999"),
        item("tweet-1860000000000000002", t2, "1998"),
        item("tweet-1860000000000000004", rt, "1997"),
        promoted,
        item("tweet-1860000000000000006", quote, "1995"),
        module("home-conversation-1860000000000000008", [
            module_item("home-conversation-1860000000000000008-tweet-1860000000000000007", conv_a),
            module_item("home-conversation-1860000000000000008-tweet-1860000000000000008", conv_b),
        ], "1994"),
        module("who-to-follow-1860", [module_item("who-to-follow-1860-user-1004", u=dev)], "1993", "Vertical"),
        item("tweet-tomb", tomb, "1992"),
        {"entryId": "messageprompt-1", "sortIndex": "1991", "content": {
            "entryType": "TimelineTimelineItem", "itemContent": {"itemType": "TimelineMessagePrompt"}}},
        {"entryId": "future-thing", "sortIndex": "1990", "content": {"entryType": "TimelineSomethingNew"}},
        cursor("Top", "DAABCgABTOP", "1999999"),
        cursor("Bottom", "DAABCgABBOTTOM", "1"),
    ]
    return {"data": {"home": {"home_timeline_urt": {"instructions": [
        {"type": "TimelineAddEntries", "entries": entries},
        {"type": "TimelineClearCache"},
    ], "responseObjects": {"feedbackActions": []}, "metadata": {"scribeConfig": {"page": "for_you"}}}}}}


def detail():
    parent = tweet("1860000000000000010", ada, "Parent post of the thread.", likes=50, replies=2)
    focal = tweet("1860000000000000011", ben, "@ada_example This is the focal reply with a photo https://t.co/AbCdEf123",
                  reply_to=("1860000000000000010", "ada_example"), conv="1860000000000000010",
                  media=[photo("700011")], likes=8, replies=2)
    focal["legacy"]["display_text_range"] = [13, len(focal["legacy"]["full_text"])]
    r1 = tweet("1860000000000000012", cleo, "@bensample First reply", reply_to=("1860000000000000011", "bensample"),
               conv="1860000000000000010")
    r1["legacy"]["display_text_range"] = [11, len(r1["legacy"]["full_text"])]
    r2 = tweet("1860000000000000013", ben, "@cleo_co Author answers", reply_to=("1860000000000000012", "cleo_co"),
               conv="1860000000000000010")
    r2["legacy"]["display_text_range"] = [9, len(r2["legacy"]["full_text"])]
    r3 = tweet("1860000000000000014", dev, "@bensample Another reply", reply_to=("1860000000000000011", "bensample"),
               conv="1860000000000000010")
    show_more = {"entryId": "conversationthread-x-cursor-showmore", "item": {"itemContent": {
        "itemType": "TimelineTimelineCursor", "__typename": "TimelineTimelineCursor", "value": "SHOWMORE",
        "cursorType": "ShowMoreThreads"}}}
    entries = [
        item("tweet-1860000000000000010", parent, "3"),
        item("tweet-1860000000000000011", focal, "2"),
        module("conversationthread-1860000000000000012", [
            module_item("conversationthread-1860000000000000012-tweet-1860000000000000012", r1),
            module_item("conversationthread-1860000000000000012-tweet-1860000000000000013", r2),
            show_more,
        ], "1"),
        module("conversationthread-1860000000000000014", [
            module_item("conversationthread-1860000000000000014-tweet-1860000000000000014", r3),
        ], "0"),
        {"entryId": "cursor-bottom-0", "sortIndex": "-1", "content": {
            "entryType": "TimelineTimelineItem", "__typename": "TimelineTimelineItem",
            "itemContent": {"itemType": "TimelineTimelineCursor", "__typename": "TimelineTimelineCursor",
                            "value": "DETAILBOTTOM", "cursorType": "Bottom"}}},
    ]
    return {"data": {"threaded_conversation_with_injections_v2": {"instructions": [
        {"type": "TimelineAddEntries", "entries": entries},
        {"type": "TimelineTerminateTimeline", "direction": "Top"},
    ]}}}


def notifications():
    liked = tweet("1860000000000000020", me, "My post people liked", likes=2)
    mention = tweet("1860000000000000021", ada, "@perch_tester hey, check this out",
                    reply_to=("1860000000000000020", "perch_tester"))
    def notif(nid, text, icon, users, ts, target=None, sort="0"):
        tpl = {"__typename": "TimelineNotificationAggregateTemplate",
               "from_users": [{"__typename": "TimelineNotificationUserRef", "user_results": {"result": u}} for u in users],
               "target_objects": ([{"__typename": "TimelineNotificationTweetRef", "tweet_results": {"result": target}}] if target else [])}
        return {"entryId": "notification-" + nid, "sortIndex": sort, "content": {
            "entryType": "TimelineTimelineItem", "__typename": "TimelineTimelineItem",
            "itemContent": {"itemType": "TimelineNotification", "__typename": "TimelineNotification",
                            "id": nid, "notification_icon": icon,
                            "rich_message": {"rtl": False, "text": text, "entities": []},
                            "notification_url": {"url": "https://x.com/i/timeline", "urlType": "DeepLink"},
                            "template": tpl, "timestamp_ms": ts}}}
    entries = [
        cursor("Top", "NOTIFTOP", "1999999"),
        notif("n1", "Ada Example and Ben Sample liked your post", "heart_icon", [ada, ben], "1763314200000", liked, "1763314200001"),
        item("tweet-1860000000000000021", mention, "1763314100000"),
        notif("n2", "Cleo &amp; Co followed you", "person_icon", [cleo], "1763300000000", None, "1763300000000"),
        cursor("Bottom", "NOTIFBOTTOM", "1"),
    ]
    return {"data": {"viewer_v2": {"user_results": {"result": {"__typename": "User", "rest_id": "2000",
        "notification_timeline": {"id": "x", "timeline": {"instructions": [
            {"type": "TimelineClearCache"},
            {"type": "TimelineAddEntries", "entries": entries},
            {"type": "TimelineMarkEntriesUnreadGreaterThanSortIndex", "sort_index": "1763310000000"},
        ]}}}}}}}


def user_by_screen_name():
    return {"data": {"user": {"result": ada}}}


def search_people():
    return {"data": {"search_by_raw_query": {"search_timeline": {"timeline": {"instructions": [
        {"type": "TimelineAddEntries", "entries": [
            user_item("user-1001", ada, "3"), user_item("user-1003", cleo, "2"), cursor("Bottom", "PEOPLEBOTTOM", "0")]}
    ]}}}}}


def user_tweets():
    pinned = tweet("1860000000000000030", ada, "Pinned post", likes=100)
    t = tweet("1860000000000000031", ada, "A regular profile post", likes=4)
    return {"data": {"user": {"result": {"__typename": "User", "timeline": {"timeline": {"instructions": [
        {"type": "TimelineClearCache"},
        {"type": "TimelinePinEntry", "entry": item("tweet-1860000000000000030", pinned, "9")},
        {"type": "TimelineAddEntries", "entries": [
            item("tweet-1860000000000000031", t, "5"), cursor("Top", "UTTOP", "10"), cursor("Bottom", "UTBOTTOM", "0")]},
    ]}}}}}}


def dm_inbox():
    return {"inbox_initial_state": {
        "last_seen_event_id": "1", "cursor": "c",
        "entries": [
            {"message": {"id": "500", "time": "1763314000000", "conversation_id": "1001-2000",
                         "message_data": {"id": "500", "time": "1763314000000", "recipient_id": "2000",
                                          "sender_id": "1001", "text": "Hi there &amp; welcome"}}},
            {"message": {"id": "499", "time": "1763313000000", "conversation_id": "1001-2000",
                         "message_data": {"id": "499", "time": "1763313000000", "recipient_id": "1001",
                                          "sender_id": "2000", "text": "Hello!"}}},
        ],
        "users": {
            "1001": {"id_str": "1001", "name": "Ada Example", "screen_name": "ada_example", "profile_image_url_https": AVATAR},
            "2000": {"id_str": "2000", "name": "Perch Tester", "screen_name": "perch_tester", "profile_image_url_https": AVATAR},
            "1003": {"id_str": "1003", "name": "Cleo", "screen_name": "cleo_co", "profile_image_url_https": AVATAR},
        },
        "conversations": {
            "1001-2000": {"conversation_id": "1001-2000", "type": "ONE_TO_ONE", "sort_timestamp": "1763314000000",
                          "participants": [{"user_id": "1001"}, {"user_id": "2000"}],
                          "last_read_event_id": "499", "max_entry_id": "500", "trusted": True},
            "1003-2000": {"conversation_id": "1003-2000", "type": "ONE_TO_ONE", "sort_timestamp": "1763200000000",
                          "participants": [{"user_id": "1003"}, {"user_id": "2000"}], "is_encrypted": True,
                          "last_read_event_id": "1", "max_entry_id": "1"},
        },
    }}


def badge():
    return {"data": {"viewer_v2": {"user_results": {"result": {"__typename": "User",
            "badge_counts": {"ntab_unread_count": 4, "dm_unread_count": 1, "total_unread_count": 5}}}}}}


def main():
    os.makedirs(OUT, exist_ok=True)
    files = {"home_timeline.json": home(), "tweet_detail.json": detail(), "notifications.json": notifications(),
             "user_by_screen_name.json": user_by_screen_name(), "search_people.json": search_people(),
             "user_tweets.json": user_tweets(), "dm_inbox.json": dm_inbox(), "badge_counts.json": badge()}
    for name, data in files.items():
        with open(os.path.join(OUT, name), "w") as fp:
            json.dump(data, fp, indent=1, sort_keys=True)
            fp.write("\n")
    print("wrote", len(files), "fixtures to", OUT)


if __name__ == "__main__":
    main()
