#!/usr/bin/env python3
"""
Generates test vectors for XKit's Swift x-client-transaction-id port.

The reference math below is taken from twscrape (xclid.py, MIT) which in turn
is based on iSarabjitDhiman/XClientTransaction (MIT). Python semantics
(banker's rounding in round(), round(x, 2)) are what the Swift port mirrors.

Usage:
  pip install beautifulsoup4
  python3 scripts/gen_xclid_vectors.py OUT_DIR page1.html [page2.html ...]

Each page is an x.com HTML document. Only the verification meta tag and the
four loading-x-anim SVGs are kept in the emitted fixture (no personal data).
"""
import base64, hashlib, json, math, os, re, sys
import bs4

INDICES = [35, 42, 37, 10]  # from sign module `(e[N],16)` pattern, 2026-11-17
KEYWORD, EXTRA = "obfiowerehiring", 3
EPOCH = 1682924400


class Cubic:
    def __init__(self, curves): self.curves = curves
    def get_value(self, time):
        start_gradient = end_gradient = start = mid = 0.0
        end = 1.0
        c = self.curves
        if time <= 0.0:
            if c[0] > 0.0: start_gradient = c[1] / c[0]
            elif c[1] == 0.0 and c[2] > 0.0: start_gradient = c[3] / c[2]
            return start_gradient * time
        if time >= 1.0:
            if c[2] < 1.0: end_gradient = (c[3] - 1.0) / (c[2] - 1.0)
            elif c[2] == 1.0 and c[0] < 1.0: end_gradient = (c[1] - 1.0) / (c[0] - 1.0)
            return 1.0 + end_gradient * (time - 1.0)
        while start < end:
            mid = (start + end) / 2
            x_est = self.calc(c[0], c[2], mid)
            if abs(time - x_est) < 0.00001: return self.calc(c[1], c[3], mid)
            if x_est < time: start = mid
            else: end = mid
        return self.calc(c[1], c[3], mid)
    @staticmethod
    def calc(a, b, m): return 3.0 * a * (1 - m) * (1 - m) * m + 3.0 * b * (1 - m) * m * m + m * m * m


def solve(v, lo, hi, rounding):
    r = v * (hi - lo) / 255 + lo
    return math.floor(r) if rounding else round(r, 2)


def float_to_hex(x):
    result = []
    quotient = int(x); fraction = x - quotient
    while quotient > 0:
        quotient = int(x / 16)
        remainder = int(x - (float(quotient) * 16))
        result.insert(0, chr(remainder + 55) if remainder > 9 else str(remainder))
        x = float(quotient)
    if fraction == 0: return "".join(result)
    result.append(".")
    while fraction > 0:
        fraction *= 16
        integer = int(fraction); fraction -= float(integer)
        result.append(chr(integer + 55) if integer > 9 else str(integer))
    return "".join(result)


def anim_key(frames, target_time):
    from_color = [*frames[:3], 1]; to_color = [*frames[3:6], 1]
    to_rot = solve(frames[6], 60.0, 360.0, True)
    curves = [solve(x, -1.0 if i % 2 else 0.0, 1.0, False) for i, x in enumerate(frames[7:])]
    val = Cubic(curves).get_value(target_time)
    color = [max(0, min(255, a * (1 - val) + b * val)) for a, b in zip(from_color, to_color)]
    rot = 0.0 * (1 - val) + to_rot * val
    rad = math.radians(rot)
    matrix = [math.cos(rad), -math.sin(rad), math.sin(rad), math.cos(rad)]
    out = [format(round(v), "x") for v in color[:-1]]
    for v in matrix:
        r = abs(round(v, 2))
        h = float_to_hex(r)
        out.append(f"0{h}".lower() if h.startswith(".") else h if h else "0")
    out += ["0", "0"]
    return re.sub(r"[.-]", "", "".join(out))


def load(html):
    soup = bs4.BeautifulSoup(html, "html.parser")
    key = soup.find("meta", {"name": "twitter-site-verification"})["content"]
    kb = list(base64.b64decode(key))
    els = [str(x.get("d") or "").strip() for x in soup.select("svg[id^='loading-x-anim'] g:first-child path:nth-child(2)")]
    arr = [list(map(float, re.sub(r"[^\d]+", " ", x).split())) for x in els[kb[5] % len(els)][9:].split("C")]
    ft = 1
    for i in INDICES[1:]: ft *= kb[i] % 16
    ft = math.floor(ft / 10 + 0.5) * 10
    row = arr[kb[INDICES[0]] % 16]
    return key, kb, row, ft, anim_key(row, ft / 4096), soup


def txid(kb, ak, method, path, ts, rnd):
    tb = [(ts >> (i * 8)) & 0xFF for i in range(4)]
    h = list(hashlib.sha256(f"{method}!{path}!{ts}{KEYWORD}{ak}".encode()).digest())
    p = [*kb, *tb, *h[:16], EXTRA]
    return base64.b64encode(bytearray([rnd, *[x ^ rnd for x in p]])).decode().strip("=")


def main():
    out = sys.argv[1]; os.makedirs(out, exist_ok=True)
    vectors = []
    reqs = [("GET", "/i/api/graphql/KmJCeZ__ef1fNos7tKN_fg/HomeTimeline", 112233445, 0),
            ("POST", "/i/api/graphql/lI07N6Otwv1PhnEgXILM7A/FavoriteTweet", 112233999, 77),
            ("GET", "/i/api/1.1/dm/inbox_initial_state.json", 120000000, 255)]
    for n, page in enumerate(sys.argv[2:], 1):
        key, kb, row, ft, ak, soup = load(open(page, encoding="utf-8").read())
        meta = soup.find("meta", {"name": "twitter-site-verification"})
        svgs = soup.select("svg[id^='loading-x-anim']")
        fixture = "<!DOCTYPE html><html><head>" + str(meta) + "</head><body>" + "".join(str(s) for s in svgs) + "</body></html>\n"
        name = f"xclid_page_{n}.html"
        open(os.path.join(out, name), "w").write(fixture)
        vectors.append({
            "fixture": name, "indices": INDICES, "verificationKey": key,
            "frameTime": ft, "frameRow": row, "animationKey": ak,
            "transactions": [{"method": m, "path": p, "time": t, "random": r, "id": txid(kb, ak, m, p, t, r)} for m, p, t, r in reqs],
        })
    json.dump(vectors, open(os.path.join(out, "xclid_vectors.json"), "w"), indent=2)
    print(json.dumps([{k: v for k, v in x.items() if k in ("fixture", "animationKey", "frameTime")} for x in vectors], indent=1))


if __name__ == "__main__":
    main()
