# Perch — guide for agents (read this first)

Perch is a personal, non-commercial X (Twitter) client for **Apple Watch** (plus a small iPhone
companion for login and sync). One user, one owner account (plus optional extra accounts),
sideloaded, never on the App Store. This file is the distilled knowledge of every session so far:
how the app is built, how it talks to X, what was researched, what was measured, and the mistakes
that cost hours. Keep it current when you learn something new (add to "Lessons" with a date).

Last full update: 2026-11-18 (Digital Crown fix shipped on `redesign`, commit `a0103de`).

---

## 1. Ground rules

- **There is no Mac.** The owner develops on Arch Linux. Everything Apple-side is built by
  **GitHub Actions** (`macos-26` runner, Xcode **26.6**, iOS SDK 26.x, watchOS SDK 26.5).
  Never hand-edit an `.xcodeproj`: the project is generated from `project.yml` by **XcodeGen** on CI.
- Deployment targets: **iOS 18.0, watchOS 11.0**. Check every API exists there; wrap newer ones in
  `if #available`. Swift language mode **5**, `SWIFT_STRICT_CONCURRENCY: minimal`, UI types `@MainActor`.
- **XKit** (`Packages/XKit`) holds all X networking/parsing and must stay free of SwiftUI/UIKit/
  WatchKit; it builds and tests on **Linux** too (`swift test`, Swift 6.x toolchain, keep the
  existing `#if canImport(...)` guards). This is the one place you can compile and test locally.
- **Secrets:** cookies/tokens live only in the Keychain. Never log, print, commit or display them;
  use `Redactor`. `RequestLog` already redacts.
- **Account safety:** behave like one light human user. Rate limiter stays on, exponential
  backoff on 429, no background polling more often than every ~15 min (watchOS decides ~30 min),
  no automation, no bulk scraping.
- Write conservative, boring Swift. A compile error costs a CI round trip (2–10 min).
- Do not push to branches you were not told to use. Ask before merging into `redesign`.
  `main` only has the initial commit; the real line is **`redesign`**.
- Do not create recurring CI jobs that commit to the repo without asking (an auto-commit
  "update endpoints" workflow was refused by the safety review once).

## 2. Repository map

```
Packages/XKit/        X client, parsers, transaction id, endpoint config, accounts, sync payload
  Sources/XKit/Core          JSON (tolerant dynamic JSON), PagerSwipe (unused by the shipped pager, tested maths)
  Sources/XKit/Auth          XCredentials, Account, KeychainStore, Redactor
  Sources/XKit/Endpoints     EndpointConfig (endpoints.json), Discovery (query-id scraper + signer finder)
  Sources/XKit/Transaction   ClientTransaction (x-client-transaction-id), SHA256 fallback for Linux
  Sources/XKit/Networking    XClient/LiveXClient, Transport (+TransferMonitor), RateLimiter,
                             RequestLog, SessionStore (multi-account store), TransactionMaterialProvider
  Sources/XKit/Parsing       XParser (URT timelines, users, threads, notifications), DMParser
  Sources/XKit/Sync          SyncPayload (iPhone → Watch), RemoteOverride
  Tests/XKitTests            parser, transaction-id vectors, client, pager-swipe, review-fix tests
Perch/                iOS app: WKWebView login (multi-account), settings, PhoneSync (WatchConnectivity)
PerchWatch/           watchOS app (all UI) — see §6
PerchWatch/Debug/     DEBUG-only fixture harness (screenshots, crown tests); excluded from Release
PerchWatchUITests/    watchOS UI tests: Digital Crown routing (CrownRoutingTests.swift)
PerchWidget/          watch-face complication (WidgetKit extension, embedded in the Watch app)
Shared/               code compiled into the iOS and Watch apps (AppModel, PagedList, ImageLoader,
                      PostStateStore, TweetViews, SwipeGuard, LinkBudget, AppGroup, Settings…)
Config/               Perch.xcconfig (PERCH_BUNDLE_ID — the one place to change bundle ids), entitlements
endpoints.json        fallback query IDs/feature flags (identical copy bundled in XKit Resources)
scripts/              update_endpoints.py, gen_xclid_vectors.py, make_mock_fixtures.py, make_icon.py
.github/workflows/    build.yml (IPA), screens.yml (screenshots + crown suite), crown.yml (crown matrix)
codemagic.yaml        fallback CI on Codemagic (unsigned IPA + crown tests) — not connected yet
docs/                 see §11 for which docs are current and which are history
```

Targets (project.yml): `Perch` (iOS app, embeds the Watch app at `Perch.app/Watch/PerchWatch.app`),
`PerchWatch` (watchOS app, `WKRunsIndependentlyOfCompanionApp = YES`, embeds `PerchWidget`),
`PerchWidget` (complication), `PerchWatchUITests` (Debug only, scheme `PerchWatchCrown`).
Bundle ids: `$(PERCH_BUNDLE_ID)`, `.watchkitapp`, `.watchkitapp.widget` (default
`com.CHANGEME.perch`). The Watch binary must contain **arm64** (Series 9/10/Ultra 2) and
arm64_32: `ARCHS = "arm64 arm64_32"`, simulator `arm64` only. CI fails the build if the Watch app
is missing from the IPA, lacks arm64, or `WKCompanionAppBundleIdentifier` ≠ iOS bundle id.

## 3. How Perch talks to X (unofficial web API)

The official API is pay-per-read, so Perch uses x.com's own web endpoints with the user's browser
session. Facts verified 2026-11-17 against live x.com and current reference code (twscrape,
XClientTransaction, twikit) — re-verify when things break, they change.

- **Auth:** cookies `auth_token` + `ct0` (+ `twid`), header `x-csrf-token: <ct0>`,
  `Authorization: Bearer <public web bearer>` (the long-standing `AAAA…%3D1Zv7…` token, still in
  the 2026 bundles), `x-twitter-auth-type: OAuth2Session`, `x-twitter-active-user: yes`, Safari UA.
  XKit sets the `Cookie` header itself; URLSession cookie storage is disabled.
- **ct0 rotation:** X may send a new `ct0` via `Set-Cookie`; XKit stores it. A 403 with error code
  **353** = csrf mismatch → retry once with the new ct0 (the web client does the same).
- **Two web apps exist** (since ~2026-10): the new **x-web** (Vite/TanStack, assets under
  `abs.twimg.com/x-web/x-web/assets/*.js`, Relay persisted queries on `api.x.com/graphql/<id>/<name>`,
  no `features` param) serves `/`, `/home`, profiles; the **legacy responsive-web** app still serves
  routes like `/i/embed`. **Perch uses the legacy GraphQL endpoints**
  `https://x.com/i/api/graphql/<queryId>/<Operation>` with `variables` + `features` (+`fieldToggles`):
  all ~21 operations Perch needs exist there (HomeTimeline, HomeLatestTimeline, TweetDetail,
  CreateTweet, FavoriteTweet, …, NotificationsTimeline, ViewerBadgeCounts, Likes, Bookmarks, …).
  Home timelines are POSTed by the web client; queries are GET, mutations POST.
  If the legacy app ever disappears, Perch must move to the x-web Relay ops (different response
  shapes) — `EndpointDiscovery` will then fail loudly ("No GraphQL operations found").
- **Query IDs change with every web build.** A stale ID usually answers **404 with an empty body**.
  Sources, in order: on-device scrape (`EndpointDiscovery`, iPhone) → optional remote override URL
  (raw `endpoints.json` in this repo) → bundled `endpoints.json`. Regenerate the files with
  `python3 scripts/update_endpoints.py` (stdlib only, no account) and commit both copies (a unit
  test checks they are identical). Ops live in `main.<hash>a.js` and chunks (HomeTimeline in
  `bundle.AudioSpacePeek`/`ComposeMedia`, NotificationsTimeline in `bundle.Notifications`,
  Bookmarks in `shared~bundle.BookmarkFolders~bundle.Bookmarks`); chunk URLs come from the
  `{id:"name"}` + `{id:"16-hex"}` maps in the page (hashes became 16 hex chars on 2026-08-24).
  Feature flag values come from `"featureSwitch":{"defaultConfig":…}` in the page HTML.
- **x-client-transaction-id:** algorithm unchanged since 2025 (verification key from
  `<meta name="twitter-site-verification">`, the 4 `loading-x-anim-N` SVG frames, cubic-bezier
  animation key, SHA-256 of `METHOD!path!time` + `obfiowerehiring` + animKey, epoch 1682924400,
  trailing byte 3). The key-byte **indices live in the signer script** and differ per build:
  legacy `ondemand.s.<hash>a.js` (`[36,45,10,47]` on 2026-11-17), x-web signer (dynamically
  imported chunk next to the `x-client-transaction-id` header plugin, `sign.o-*.js` when logged in)
  (`[35,42,37,10]`). Perch tries the logged-in x-web page first, then `/i/embed`, then the indices in
  `endpoints.json`. The Swift port matches the Python reference math (Python rounding semantics —
  banker's `round()`, `round(x, 2)` via `%.2f`) on vectors from 4 real pages
  (`scripts/gen_xclid_vectors.py`, `Tests/XKitTests/Fixtures`). On 404 the client regenerates the
  material once before blaming the query ID. The iPhone computes the material and syncs it; the
  Watch can refresh it itself.
- **Response parsing:** URT shape `instructions → entries → content → itemContent →
  tweet_results.result`. The parser is tolerant: unknown entry types (ads, who-to-follow, prompts)
  are skipped, `TweetWithVisibilityResults` unwrapped, tombstones kept, promoted entries dropped.
  **Since 2026-05 users/tweets may come with `legacy = null`** (twscrape `_flatten_user_v2`): fields
  moved to `core.{name,screen_name}`, `avatar.image_url`, `banner.image_url`, `profile_bio`,
  `relationship_counts`, `tweet_counts`, top-level tweet fields… Build a flat dictionary
  (top-level keys, missing ones filled from `legacy`). **TweetDetail** mixes in "Discover more"
  (`tweetdetailrelatedtweets-*`); real replies are those replying to the focal id; reply cursor
  preference `ShowMoreThreads` → `ShowMoreThreadsPrompt` → `Bottom`. Schema breaks surface as
  errors, not empty lists.
- **Other endpoints:** follow/unfollow `POST /i/api/1.1/friendships/{create,destroy}.json`;
  badge counts = GraphQL `ViewerBadgeCounts`; mark notifications seen = `POST
  /i/api/2/notifications/all/last_seen_cursor.json`; legacy DMs `/i/api/1.1/dm/*`. X "Chat"
  (end-to-end encrypted, passcode key) is not readable — mark such threads "Open on iPhone".
- **Errors the UI must handle without crashing:** 401 (session expired → banner asking the
  iPhone to resend cookies; the Watch never deletes the session itself), 403, 404 (refresh
  endpoints), 429 (backoff with `x-rate-limit-reset`), GraphQL `errors` with HTTP 200.

## 4. Login, accounts and sync

- **iPhone login:** non-persistent `WKWebView` on `x.com/i/flow/login` (Safari UA). When
  `auth_token` + `ct0` appear and the page has left `/flow`, `/login`, `/account`, they are stored
  in the Keychain. Website data is wiped before each new login so a second account never inherits
  the first one's cookies. Fallback: paste `auth_token`/`ct0` from desktop DevTools.
- **Multi-account:** accounts live in `XSessionStore` (Keychain); `Account.id` = X user id or a
  stable hash. Each device keeps its own active account. Offline caches are namespaced per account;
  logout keeps saved posts and the image cache (owner's decision 2026-11-18).
- **WatchConnectivity** (`PhoneSync` / `WatchSync`): the iPhone pushes a `SyncPayload` (accounts,
  endpoint config only when it changed, transaction material) via `updateApplicationContext` +
  `transferUserInfo` (+ `sendMessage` when reachable). The Watch ignores payloads older than the last
  applied one (persisted), asks once for the config if its version differs, and can request a sync.
  Logout propagates both ways. The Watch talks to x.com directly afterwards (Wi-Fi/LTE or via phone).

## 5. Building, CI and distribution

- **build.yml** (push, skips docs-only changes): xcodegen → XKit `swift test` → `xcodebuild archive`
  unsigned → `Perch-unsigned.ipa` artifact (+ checks above). ~4 min. This is the IPA to install.
- **screens.yml** (push to `redesign`/`crown-lab`, manual): DEBUG build for the watch simulator,
  screenshots of fixture screens (`-PerchScreen feed|menu|post|profile|media|notifications|longpost`),
  then the full crown suite (3 cold launches, ~35–40 min). Cancel it if you only need the build.
- **crown.yml** (manual only): crown routing UI tests, one job per `variants` entry, inputs
  `variants` (JSON list, `["A"]` = shipped code), `iterations`, `only` (scenario ids). Prints
  `CROWN S<n> k/n VERDICT …` lines and a table job.
- **Minutes:** macOS minutes count **10×** on private repos; on 2026-11-18 the free allowance ran out
  and every job failed in 2 s with no logs ($0 budgets = "usage blocked"). The repo is **public** now,
  so standard runners are free. Do not run long macOS suites on every push. Do not suggest a second
  GitHub account for more minutes (one free account per person — ToS). Fallback: `codemagic.yaml`
  (500 free M2 minutes/month on a personal account; the owner has not connected it yet).
- **Install (owner's laptop):** `perch-sideload fetch` (check run id vs git log) then
  `perch-sideload wsign` (Plume Impactor/plumesign, free Apple ID). Free-account limits: 7-day
  signatures, 10 App IDs/week, 3 active sideloaded apps. That route signs the iPhone and Watch apps
  but **strips the complication `.appex`**, and a free team may not get the App Group container —
  the app degrades gracefully (`AppGroup.identifier == nil`, Settings shows it). The Watch UDID must
  be registered on the team (pymobiledevice3 `companion list` gives it). Free-provisioning profiles
  list devices; certificates do not. See `docs/SIDELOADING.md`.
- The owner wants **no interim installs**: install only after the simulator tests show a fix works.

## 6. Watch app architecture (current, `redesign` @ a0103de)

- **Root:** `WatchRootView` → `NavigationStack(path: Navigator.path)` → `RootPager`.
  `RootPager` is the **system pager**: `TabView(selection:)` with `.page(indexDisplayMode: .never)`,
  pages **Menu (0) · For You (1) · Following (2)**, starting on the stored `homeKind` (For You by
  default). The leading toolbar button toggles menu ↔ last feed. Menu entries push onto the root
  stack. The edge glow (`RootGlow`) overlays the whole pager.
- **Feeds** (`HomeView`): `ScrollView` + `LazyVStack` on pure black (no `List`: watchOS draws grey
  platters), Parrot-style posts (`FeedPostView`), disk cache shown instantly, `PagedList` for
  paging/refresh, `PullToRefresh` (custom: watchOS accepts `.refreshable` but draws nothing; crown
  at the top rubber-bands and a big turn refreshes), status pill with transfer rate.
  `returnToken`: when a feed is **swiped back to**, its scroll view gets a new identity and is
  scrolled back to the post that was on top (needed for the crown, see §8).
- **Media:** `MediaPresenter.shared` holds the target. At the root it is presented with a
  **`fullScreenCover`** (watchOS draws its own X; the viewer's own X is hidden there via
  `showsCloseButton: false`; `._statusBarHidden(true)` tries to hide the clock — unverified on
  device). Inside the profile sheet a `MediaHost` overlay is still used (one host per presentation
  context; `sheetDepth` decides which draws). Viewer: swipe between attachments, swipe down or hand
  double-tap to close, crown zoom (photos) / volume + scrub (videos via `WKInterfaceVolumeControl`),
  lowest-bitrate MP4 first, background audio playback (Now Playing), GIFs loop.
- **Navigation details:** `SwipeBack` (forgiving swipe-right-to-pop, pops by state via
  `Navigator.back()` so it cannot race the system pop), `SwipeGuard` (a tap that ends a horizontal
  swipe must not also fire the control under the finger), `ScreenNavigation` (popScreen/pushProfile
  environment values). Profiles open in a sheet (`ProfileSheet`) with its own stack.
- **State:** `AppModel` (shared, account/client/badge/sync), `PostStateStore` (optimistic
  like/repost/bookmark with per-post workers and an **offline queue** replayed on refresh/foreground),
  `PagedList` (one loader for every list, phases drive `PagedListStatus`), `OfflineCache` (threads,
  profiles), `SavedStore` (saved posts with media in Application Support), `ImageLoader`
  (downsampling, memory budget, LRU disk cache, feed prefetch keyed exactly like display via
  `ImageLoader.feedImage(for:)`), `LinkBudget` (one answer to "can the link carry N bytes in time").
- **Background:** `BackgroundRefresh` (~30 min, watchOS decides) refreshes the feed cache, badge and
  the complication snapshot (`AppGroup`).

## 7. Testing

- **XKit unit tests** (Linux and CI): parser fixtures (anonymised, incl. v2 schema), transaction-id
  vectors, client request shapes/status mapping/backoff, sync payload, pager-swipe maths.
- **DEBUG fixture harness** (`PerchWatch/Debug`): `-PerchFixtures YES` installs `FixtureXClient`
  (JSON in `PerchWatch/Debug/Fixtures`, includes photo, very tall image, long post, video, a GIF,
  v2 user). `-PerchScreen <name>` opens a screen directly. `-PerchFixtureFirst <tweet id>` moves a
  post to the top (used by media tests). Likes/Bookmarks fixtures return the home posts so those
  lists can scroll. Release excludes the folder (`EXCLUDED_SOURCE_FILE_NAMES` + `#if DEBUG`).
- **Crown routing tests** (`PerchWatchUITests/CrownRoutingTests.swift`): each scenario cold-launches,
  navigates, then turns the crown with **no touch** and checks the visible list's offset via a
  DEBUG-only `.crownProbe("name")` (republishes `contentOffset.y` as an invisible accessibility
  element `probe.<name>`; it uses no focus/disabled/gesture so it cannot change routing).
  Scenario ids: S1 cold launch, S2/S3 swipe to Following and back, S4 swipe to menu, S5 menu →
  toolbar → feed, S6 hamburger, S7/S7b/S8 Likes/Notifications push/back, S9–S11 post open/back
  (button, swipe), S12 photo, S14 video, S21 GIF, S15/S16 profile sheet open/close, S17 crown at
  the top, S18/S19 Bookmarks push/back, S20 Notifications back, S22 post back + hamburger, S23
  Bookmarks swipe-pop (black-screen check). Env: `TEST_RUNNER_CROWN_VARIANT`,
  `TEST_RUNNER_CROWN_ITERATIONS`, `TEST_RUNNER_CROWN_ONLY`.
- Results history: `docs/crown/PHASE2-REPORT.md`. Shipped code: every measured scenario passes.
  Not measured: S7/S7b/S8/S20 (menu Likes/Notifications row taps), media opened inside the profile
  sheet, S16/S21 were flaky in the harness (UI busy) but passed in other runs.
- The simulator reproduced every device-reported crown symptom, so **measure in CI before asking the
  owner to install**.

## 8. The Digital Crown — what we learned (2026-11-18)

Symptom on device: the crown did nothing until a finger touched the list, after page swipes, the
hamburger/back buttons, pops, sheet dismissal and closing media. Eight rounds of focus code had
not fixed it. What the measurements showed:

1. **Never put explicit focus on a plain scroll view** (`@FocusState`, `.focusable()`,
   `.focused()`, `prefersDefaultFocus`, `resetFocus`, re-focus timers). It suppresses watchOS' own
   routing. watchOS routes the crown to the visible `List`/`ScrollView` by itself. (`.focusable()`
   + `.focused()` is correct only next to `digitalCrownRotation`, e.g. the media pages.)
2. **Several live scroll views side by side kill routing.** The old hand-rolled pager (three pages
   in an `HStack` moved by `.offset`, off-screen ones `.disabled`) left the crown pointing nowhere
   whenever a feed became visible again. Keeping only the visible page in the tree fixed most cases;
   the **system `TabView(.page)` pager fixed all pager cases** (incl. toolbar buttons). Measured
   variants: P (only visible page) partial, S (`scrollDisabled`) no, F (`focusable(false)` on the
   toolbar button) no, T (TabView) yes.
3. **A scroll view gets the crown when it appears**, not when a swipe merely brings it back.
   Swiping back to an already-shown feed (S3) needed `returnToken` (new identity + scroll back to the
   top-visible post). Rebuilding on *every* transition also works but resets the scroll position —
   do not ship that.
4. **Overlay presentations do not hand the crown back.** A media viewer drawn as a ZStack overlay
   left the crown dead after closing; a **real presentation (`fullScreenCover`)** fixes it,
   because dismissal is a moment watchOS re-picks the crown target. Trade-off accepted by the owner:
   system X + clock in the viewer.
5. A page-style `TabView` inside the root `NavigationStack` once showed a **black screen after a
   swipe-pop**; that came from the custom swipe-back racing the system pop. With pops done by state
   (`Navigator.back()`), S23 shows no black screen with the TabView pager.
6. The menu `List` recovers by itself after pops; only feed `ScrollView`s were affected.

## 9. Lessons and pitfalls (do not repeat)

**watchOS / SwiftUI**
- No API for wrist flick. Hand double-tap (pinch) scrolls the focused list unless a view claims
  `.handGestureShortcut(.primaryAction)` — don't claim it in feeds (it was "like" once).
- The keyboard cannot be opened programmatically; use `TextFieldLink` (opens input on tap).
- `MagnifyGesture` is unavailable on watchOS; zoom with the crown + tap.
- `.refreshable` draws nothing on watchOS (custom pull-to-refresh exists). `.badge` is iOS-only.
- `ProgressView` inside a capsule renders as a big grey disc — use text/custom shapes.
- `List` draws grey platters; the feed uses `ScrollView` + `LazyVStack`.
- `.scrollPosition(id:)` binding is rewritten on every scroll and re-applied on list updates → the
  feed jumped. Use `ScrollViewReader` and scroll explicitly, once.
- Don't `.clipped()` or `.ignoresSafeArea()` the pager: it cut the feed / removed insets (measured).
- Swipe gestures must be `simultaneousGesture` (exclusive ones break vertical scrolling); then
  guard taps with `SwipeGuard`. Tap gestures on media instead of `Button` (button press state
  fought the scroll view).
- Streaming `AVPlayer` gives no usable progress on watchOS: download the lowest-bitrate MP4 first.
- `#if DEBUG` everything debug: a debug hook outside it broke the Release archive once.
- Watch networking is slow (often via the phone over Bluetooth): prefetch adaptively, small images.

**X API**
- 404 with an empty body = stale query ID *or* bad transaction id. Refresh material once, then endpoints.
- Logged-out x-web pages contain the signer too, but twscrape treats logged-in pages as authoritative.
- Keep feature flags = the op's declared `featureSwitches` with defaults from the page; missing ones
  cause 400 "features cannot be null".

**Tests / CI harness**
- XCUITest cannot see identifiers on some `List` rows (menu): fall back to labels, don't scroll first.
- A faded control (opacity 0, `allowsHitTesting(false)`) still looks "hittable" to XCUITest — expose
  its visibility (accessibilityValue) and check it.
- Elements inside a `fullScreenCover` can report infinite frames; tap absolute coordinates taken
  from a finite frame, or the element, never `element.coordinate` blindly.
- Autoplaying media keep the app busy → "Timed out while evaluating UI query"; start media tests with
  the post first (`-PerchFixtureFirst`), avoid long scrolls past videos.
- A list already at its end cannot move: turn the crown both ways before calling it dead.
- Measure many variants in one CI run (matrix + DEBUG switches) instead of one guess per round; then
  delete the experiment code once a winner ships.

**Process**
- The auto-mode safety review refused: running X's obfuscated signer JS in a headless browser, and
  an auto-committing scheduled workflow. Use open-source reference implementations for test vectors.
- Ask the owner before visible UX trade-offs (e.g. the viewer's X/clock) and before merging.
- Report honestly what was not measured.

## 10. How to keep things working

- **Endpoints broke (404s, "missing operation")**: iPhone → Refresh endpoints; or run
  `scripts/update_endpoints.py`, commit both `endpoints.json` copies, and (optionally) point the
  app's remote override URL at the raw file on `redesign`.
- **Search/actions fail but timelines work**: refresh the signing key (transaction material);
  check `Discovery.swift` signer patterns against the current x.com bundles.
- **Parser returns nothing**: capture a response (redacted), add an anonymised fixture, fix
  `XParser`, add a test. Check for new `legacy = null`-style moves first.
- **Crown regressions**: run `crown.yml` with `variants=["A"]` and the relevant `only` list before
  any install; add a scenario for every new screen/presentation path.
- **UI changes**: run `screens.yml` (manual dispatch on your branch) and look at the screenshots.
- **Signature expiry**: free-account installs expire after 7 days; re-run `perch-sideload wsign`.

## 11. Docs index

- `docs/PLAN.md` — original plan + 2026-11-17 research table (some architecture lines predate the
  redesign; this file wins where they differ).
- `docs/SIDELOADING.md` — install guide, free-account route, troubleshooting.
- `docs/REDESIGN.md`, `docs/REDESIGN-2.md` — redesign specs (product decisions, item ids R1–R21).
- `docs/IDEAS.md` — owner's backlog and status.
- `docs/crown/` — crown investigation: `PLAN.md` (audit), `PHASE1-*` (harness), `PHASE2-REPORT.md`
  (all measurements), `HANDOFF.md` (latest state).

## 12. Open items (2026-11-18)

- Device test of build `a0103de` (crown everywhere, viewer look, swipe-back keeps the place).
- Media opened inside the profile sheet still uses the overlay host (crown after close unmeasured).
- Crown tests for Likes/Notifications pushed from the menu (harness row taps).
- Whether `._statusBarHidden(true)` hides the clock inside the cover.
- `docs/IDEAS.md` open items (full offline Likes/Bookmarks, animation polish).
