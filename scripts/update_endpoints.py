#!/usr/bin/env python3
"""
Regenerates endpoints.json (GraphQL query IDs + feature flags) from x.com's
public, logged-out web bundles. No account or cookies are used.

  python3 scripts/update_endpoints.py            # writes endpoints.json + XKit copy
  python3 scripts/update_endpoints.py --check    # exit 1 if anything is missing

Only the Python standard library is needed. The same logic runs on the iPhone
(XKit `EndpointDiscovery`), this script exists so a GitHub Action can keep the
repo's endpoints.json fresh for the app's "remote override URL".
"""
import concurrent.futures as cf
import datetime as dt
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_FILES = [os.path.join(ROOT, "endpoints.json"),
             os.path.join(ROOT, "Packages/XKit/Sources/XKit/Resources/endpoints.json")]
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
      "(KHTML, like Gecko) Version/18.1 Safari/605.1.15")
BEARER = ("AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D"
          "1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA")

# Operations Perch uses. Keep in sync with XKit `Operation`.
OPERATIONS = [
    "HomeTimeline", "HomeLatestTimeline", "TweetDetail", "TweetResultByRestId",
    "CreateTweet", "DeleteTweet", "FavoriteTweet", "UnfavoriteTweet",
    "CreateRetweet", "DeleteRetweet", "CreateBookmark", "DeleteBookmark", "Bookmarks", "Likes",
    "UserByScreenName", "UserByRestId", "UserTweets", "UserTweetsAndReplies",
    "SearchTimeline", "NotificationsTimeline", "Viewer", "ViewerBadgeCounts",
]

OP_RE = re.compile(
    r'queryId:"([^"]+)",operationName:"([^"]+)",operationType:"([a-z]+)",'
    r'metadata:\{featureSwitches:\[([^\]]*)\],fieldToggles:\[([^\]]*)\]')
INDICES_RE = re.compile(r"\(\w\[(\d{1,2})\],\s*16\)")


def get(url, cache=None):
    if cache:
        fn = os.path.join(cache, re.sub(r"[^\w.-]", "_", url.split("://", 1)[1])[-200:])
        if os.path.exists(fn):
            return open(fn, encoding="utf-8", errors="replace").read()
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=40) as r:
        text = r.read().decode("utf-8", "replace")
    if cache:
        os.makedirs(cache, exist_ok=True)
        open(fn, "w", encoding="utf-8").write(text)
    return text


def legacy_scripts(html):
    urls = re.findall(r"https://abs\.twimg\.com/responsive-web/client-web/[\w.~-]+\.js", html)
    hm = {m.group(1): m.group(2) for m in re.finditer(r'(\d+):"([0-9a-f]{7}|[0-9a-f]{16})"', html)}
    nm = {}
    for m in re.finditer(r'(\d+):"([^"]+)"', html):
        if not re.fullmatch(r"[0-9a-f]{7}|[0-9a-f]{16}", m.group(2)):
            nm[m.group(1)] = m.group(2)
    for k, v in hm.items():
        urls.append(f"https://abs.twimg.com/responsive-web/client-web/{nm.get(k, k)}.{v}a.js")
    return [u for u in dict.fromkeys(urls)
            if not re.search(r"/i18n/|countries-|emoji|icons", u)]


def feature_defaults(html):
    m = re.search(r'"featureSwitch":\{"defaultConfig":(\{.*?\}\}),"debug"', html)
    out = {}
    if not m:
        # Fallback: scan for "name":{"value":true|false}
        for k, v in re.findall(r'"([a-z0-9_]+)":\{"value":(true|false)\}', html):
            out[k] = v == "true"
        return out
    try:
        cfg = json.loads(m.group(1))
        for k, v in cfg.items():
            if isinstance(v, dict) and isinstance(v.get("value"), bool):
                out[k] = v["value"]
    except json.JSONDecodeError:
        for k, v in re.findall(r'"([a-z0-9_]+)":\{"value":(true|false)\}', m.group(1)):
            out[k] = v == "true"
    return out


def names(s):
    return re.findall(r'"([^"]+)"', s)


def main():
    check = "--check" in sys.argv
    cache = None
    if "--cache" in sys.argv:
        cache = sys.argv[sys.argv.index("--cache") + 1]

    html = get("https://x.com/i/embed", None)
    defaults = feature_defaults(html)
    scripts = legacy_scripts(html)
    # main.js first (holds most ops), then everything else.
    scripts.sort(key=lambda u: (0 if "/main." in u else 1 if "bundle." in u else 2, u))

    found = {}
    legacy_indices = []

    def scan(text):
        for qid, name, typ, fs, ft in OP_RE.findall(text):
            if name in OPERATIONS and name not in found:
                found[name] = {"queryId": qid, "type": typ, "features": names(fs), "fieldToggles": names(ft)}

    head, rest = scripts[:1], scripts[1:]
    for u in head:
        scan(get(u, cache))
    with cf.ThreadPoolExecutor(16) as ex:
        for u, text in zip(rest, ex.map(lambda u: _safe_get(u, cache), rest)):
            if text:
                scan(text)
                if "/ondemand.s." in u:
                    legacy_indices = [int(x) for x in INDICES_RE.findall(text)]

    used_features = sorted({f for op in found.values() for f in op["features"]})
    feature_values = {f: bool(defaults.get(f, False)) for f in used_features}

    previous = {}
    if os.path.exists(OUT_FILES[0]):
        try:
            previous = json.load(open(OUT_FILES[0]))
        except Exception:
            previous = {}
    missing = [o for o in OPERATIONS if o not in found]
    ops = {k: found[k] for k in OPERATIONS if k in found}
    # Keep previously known IDs for anything we failed to find this time.
    for k in missing:
        if k in previous.get("operations", {}):
            ops[k] = previous["operations"][k]

    signer = previous.get("signer", {"indices": [35, 42, 37, 10], "source": "x-web"})
    out = {
        "version": 1,
        "updatedAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "bearer": BEARER,
        "graphqlBase": "https://x.com/i/api/graphql",
        "operations": ops,
        "featureValues": feature_values,
        "signer": signer,
        "legacySigner": {"indices": legacy_indices or previous.get("legacySigner", {}).get("indices", []),
                         "source": "legacy"},
    }

    old_cmp = {k: v for k, v in previous.items() if k != "updatedAt"}
    new_cmp = {k: v for k, v in out.items() if k != "updatedAt"}
    if old_cmp != new_cmp:
        for f in OUT_FILES:
            with open(f, "w") as fp:
                json.dump(out, fp, indent=2, sort_keys=True)
                fp.write("\n")
        print("endpoints.json updated")
    else:
        print("endpoints.json unchanged")
    print(f"found {len(found)}/{len(OPERATIONS)} operations; missing: {missing}")
    return 1 if (check and missing) else 0


def _safe_get(u, cache):
    try:
        return get(u, cache)
    except Exception as e:
        print("warn:", u, e, file=sys.stderr)
        return None


if __name__ == "__main__":
    sys.exit(main())
