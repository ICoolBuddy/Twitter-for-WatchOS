# Perch — plan & verified facts

Personal, non-commercial X client for Apple Watch (Series 10) + iPhone (15 Pro).
Built entirely on GitHub Actions (no Mac). Sideloaded.

## What was verified, and when

All of this was checked on **2026-11-17** by downloading x.com's live public
pages/bundles and reading the most recent reference implementations
(vladkens/twscrape @ 2026-11-14, iSarabjitDhiman/XClientTransaction v1.0.3 @ 2026-06-26,
d60/twikit @ 2026-03). Re-verify when things break.

| Topic | Finding |
|---|---|
| Web clients | x.com now serves **two** web apps. The new **x-web** (Vite/TanStack, `abs.twimg.com/x-web/x-web/assets/*.js`) for `/`, `/home`, profiles. It uses **Relay persisted queries** at `https://api.x.com/graphql/<id>/<name>?variables=…` (no `features` param). Routes not yet ported (e.g. `/i/embed`, most `/i/*`) still serve the **legacy responsive-web** app (`abs.twimg.com/responsive-web/client-web/main.<hash>a.js` + chunk map). |
| API we use | The **legacy GraphQL** endpoints `https://x.com/i/api/graphql/<queryId>/<Operation>` with `variables`, `features`, `fieldToggles`. twscrape still uses these successfully (Nov 2026). All 21 operations Perch needs exist in the legacy bundles (HomeTimeline, HomeLatestTimeline, TweetDetail, CreateTweet, FavoriteTweet, …, NotificationsTimeline, ViewerBadgeCounts). Home timelines are POSTed by the web client. |
| Where query IDs live | `main.<hash>a.js` has most. HomeTimeline/HomeLatestTimeline are in `bundle.AudioSpacePeek`/`bundle.ComposeMedia` chunks, NotificationsTimeline in `bundle.Notifications`, Bookmarks in `shared~bundle.BookmarkFolders~bundle.Bookmarks`. Chunk URLs are rebuilt from the `{id:"name"}` + `{id:"16-hex-hash"}` maps (`<name>.<hash>a.js`; hashes became 16 hex chars on 2026-08-24). Pattern: `queryId:"…",operationName:"…",operationType:"…",metadata:{featureSwitches:[…],fieldToggles:[…]}`. |
| Feature flag values | From `"featureSwitch":{"defaultConfig":{"name":{"value":bool}}}` in the page HTML. |
| Bearer | Unchanged public web bearer `AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7…` (present in x-web bundle too). |
| Auth headers | x-web sets `Authorization: Bearer …`, `x-csrf-token: <ct0>`, `x-twitter-auth-type: OAuth2Session` (when authenticated). It also auto-retries 403 code **353** with a refreshed `ct0` from Set-Cookie — XKit does the same. |
| `x-client-transaction-id` | Algorithm unchanged: verification key from `<meta name="twitter-site-verification">`, 4 `loading-x-anim-N` SVGs, cubic-bezier animation, SHA-256 of `METHOD!path!time` + `obfiowerehiring` + animKey, epoch 1682924400, extra byte 3. **Signer location changed**: legacy build → `ondemand.s.<hash>a.js` (indices **[36,45,10,47]** today); x-web build → a dynamically imported chunk next to the `x-client-transaction-id` header plugin (`sign.o-*.js` when logged in; hashed name when logged out), indices **[35,42,37,10]** today. twscrape uses the x-web signer from a logged-in page. Perch tries logged-in `/home` first, then `/i/embed`, and falls back to indices shipped in `endpoints.json`. |
| Unit-test vectors | Generated with the Python reference math (`scripts/gen_xclid_vectors.py`) against 4 real x.com pages captured 2026-11-17 (only the meta tag + SVGs are kept). Note: running X's own obfuscated signer in a headless browser to cross-check was deliberately not done. |
| Rest endpoints | `POST /i/api/1.1/friendships/create.json` / `destroy.json` (form `user_id=`), DMs `GET /i/api/1.1/dm/inbox_initial_state.json`, `GET dm/conversation/<id>.json`, `POST dm/new2.json` — all still referenced by the legacy bundle. Badge counts moved to GraphQL `ViewerBadgeCounts`. |
| Encrypted DMs | X "Chat" (E2EE, passcode-protected key) isn't readable via the legacy DM API; no sane documented method exists. Perch marks such threads "Open on iPhone". |
| CI | `macos-26` (arm64) runner, Xcode **26.6** default (26.0.1–26.6 installed; Xcode 27 only as preview). watchOS SDK 26.5. `macos-14` retired 2026-11-02. |
| XcodeGen | Embeds a `platform: watchOS` `application` dependency into `$(CONTENTS_FOLDER_PATH)/Watch` ("Embed Watch Content") automatically. |

## Architecture

```
Packages/XKit/      shared Swift package (builds & tests on Linux too)
  Core/JSON          tolerant dynamic JSON
  Models/            XTweet, XUser, XMedia, TimelinePage, notifications, DMs
  Parsing/           URT timeline parser (skips ads/modules/unknown), DM parser
  Transaction/       pure-Swift x-client-transaction-id + HTML extraction
  Endpoints/         EndpointConfig (endpoints.json), EndpointDiscovery (bundle scraper),
                     TransactionMaterialFetcher (signer discovery)
  Networking/        LiveXClient (GraphQL/REST), MockXClient (demo), RateLimiter,
                     RequestLog (redacted), XSessionStore (Keychain + cache)
  Auth/              XCredentials, KeychainStore, Redactor
  Sync/              SyncPayload (iPhone → Watch), RemoteOverride
Perch/              iOS app: WKWebView login, manual cookie paste, settings, sync, fallback viewer
PerchWatch/         watchOS app (UI)
endpoints.json      fallback query IDs/features (same file is bundled in XKit and used as remote override)
scripts/            update_endpoints.py, gen_xclid_vectors.py, make_mock_fixtures.py, make_icon.py
```

Data flow: iPhone logs in → cookies → Keychain → `SyncPayload` via WatchConnectivity
(`updateApplicationContext` + `transferUserInfo`). iPhone also scrapes endpoints and
transaction material and syncs them. The Watch talks to x.com directly (works without the phone)
and can refresh material itself if X returns 404.

Account safety: min 350 ms between requests, 429 → exponential backoff (60 s doubling, max 15 min,
honours `x-rate-limit-reset`) during which no request is sent; no background polling more than
every 15 minutes; promoted content not requested; nothing automated.

## Milestones

1. **CI → IPA** with iOS app + embedded Watch app (arm64 + arm64_32), verification step. ← *in progress*
2. Login (WKWebView + manual paste), Keychain, WatchConnectivity sync, settings, debug log.
3. Home timeline read-only on Watch (For You / Following, pagination, refresh, images).
4. Actions: like, repost, bookmark, reply, new post (optimistic + rollback).
5. Remaining MVP: notifications + badge, profile + follow, search (posts/users), post detail.
6. Stretch: bookmarks list, video, DMs, complication, offline cache.

## Open questions / risks

- Whether X accepts transaction IDs built from the logged-out x-web signer for logged-in
  legacy-endpoint calls. Perch prefers the logged-in page, so this only matters as a fallback.
- The legacy responsive-web app is being phased out route by route. When it disappears
  completely, Perch will need to move to x-web Relay ops on `api.x.com` (different response shapes).
  `EndpointDiscovery` will then fail loudly ("No GraphQL operations found") rather than silently.
