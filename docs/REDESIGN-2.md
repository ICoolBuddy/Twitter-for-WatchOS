# Perch redesign — round 2 (2026-11-17)

Builds on docs/REDESIGN.md (read its "Hard constraints" — they all still apply: no local Swift
compiler, CI-only builds, watchOS 11 / iOS 18 targets, Swift 5 mode, stay in your files, commit,
never push). This round fixes what the user found on the real Watch. **Design priority: clean and
minimal.** Every interactive control (buttons, labels in buttons) must be visually centred in its row
or column — check `frame(maxWidth: .infinity)` + alignment on every Button you touch.

Each item has an id (R1…). Mention the ids you completed in your report.

## Research facts (verified, do not re-research)

- **Wrist flick has no API** (Apple, WWDC25 lab): the system uses it to dismiss / go to the watch face.
  Apps cannot hook it. Do not try.
- **Hand double-tap (pinch)**: on watchOS 11 the system already scrolls the focused List/ScrollView
  with double tap *unless* a view claims it with `.handGestureShortcut(.primaryAction)`. Our feed
  claimed it for "like" — that must go (R5). In the media viewer the double tap should close it.
- **Keyboard**: there is no reliable way to open the keyboard automatically when a view appears on
  watchOS (`@FocusState` does not do it). `TextFieldLink` (watchOS 9+) is a control that opens the
  system text input (keyboard / dictation / scribble) **directly when tapped**. Use it for reply.
- **X JSON changed in 2026-05** (twscrape `twscrape/utils.py` `_flatten_user_v2` / `_flatten_tweet_v2`):
  User and Tweet results may come with `legacy = null`. User fields moved:
  - `core.{screen_name,name,created_at}`; `avatar.image_url`; `banner.image_url` (banner);
    `location.location`; `privacy.protected`; `verification.{verified,verified_type}`;
    `is_blue_verified` (top level); `profile_bio.{description,entities}`;
    `relationship_counts.{followers,following}`; `tweet_counts.{tweets,media_tweets}`;
    `action_counts.favorites_count`; `pinned_items.tweet_ids_str`.
  - Tweet fields moved from `legacy.*` to the top level of the tweet result (same key names:
    `full_text`, `favorite_count`, `retweet_count`, `reply_count`, `entities`, `extended_entities`,
    `in_reply_to_status_id_str`, `conversation_id_str`, `favorited`, `retweeted`, `bookmarked`, …).
  - Rule (same as twscrape): build a flat dictionary = top-level keys, missing keys filled from
    `legacy` if it is an object; then apply the user sub-object mappings above **only when the flat
    key is missing or empty**. Old schema keeps working.
- **TweetDetail replies** (twscrape `tweet_replies`): real replies are the tweets whose
  `in_reply_to_status_id_str == focalId`. X mixes in "Discover more" recommended posts (entry ids
  starting `tweetdetailrelatedtweets-`, and other conversations). The "more replies" cursor has
  `cursorType` `ShowMoreThreads` / `ShowMoreThreadsPrompt` / `Bottom`.
- **Video on watchOS**: streaming with AVPlayer gives no usable progress on watchOS. Download the mp4
  file first with a URLSession data/download task (count bytes → progress + bytes/s), save to Caches,
  then play the local file with AVPlayer. Watch networking (often via the iPhone over Bluetooth) is
  slow: pick the **lowest-bitrate mp4** variant.

## Items

### core (XKit + AppModel)
- **R1 Profile counts/banner/bio**: implement the flat-user rule above in `XParser.user(_:)` and the
  flat-tweet rule in `XParser.tweet(_:)`. Unit tests with hand-written v2 JSON (legacy null) AND the
  existing v1 fixtures must pass: followers/following/posts counts, banner URL (`banner.image_url`,
  append nothing), bio, verified, avatar; tweet text/counts/media/in_reply_to with legacy null.
- **R2 Replies only**: `XParser.thread` returns as `replies` only items whose first tweet is a direct
  reply to the focal tweet (`inReplyToStatusId == focalId`) — conversation modules keep their whole
  chain if its first tweet qualifies. Skip entries whose entryId starts with
  `tweetdetailrelatedtweets`. Reply pagination cursor: prefer `ShowMoreThreads`, then
  `ShowMoreThreadsPrompt`, then `Bottom`. Unit tests (focal + 2 replies + 2 related posts → 2 replies).
- **R3 Transfer stats**: `public final class TransferMonitor: @unchecked Sendable` in XKit
  (`Networking/TransferMonitor.swift`), `static let shared`,
  `public struct Snapshot: Sendable { public var activeRequests: Int; public var bytesReceived: Int64;
  public var bytesPerSecond: Double }`, `public func snapshot() -> Snapshot` (bytes/s over the last
  ~1.5 s, 0 when idle), `public func begin() -> UUID`, `public func add(_ bytes: Int, to id: UUID)`,
  `public func end(_ id: UUID)`. Thread-safe with NSLock. `URLSessionTransport.send` uses
  `session.bytes(for:)` on Darwin (`#if canImport(Darwin)`) and feeds the monitor per 16 KB chunk
  (keep the existing `data(for:)` path on Linux). Also add a public
  `static func formatRate(_ bps: Double) -> String` ("12 KB/s", "1.2 MB/s").
- **R4 Defaults**: default home timeline = **For You** (`PerchSettings.registerDefaults`).
  `AppModel.switchAccount(to:)` additionally sets `UserDefaults homeKind = forYou`.
- **R15 Debug harness hook** (DEBUG only, for screenshot tests — never in Release builds):
  `#if DEBUG func installDebugSession(client: XClient, viewer: XUser)` in AppModel that makes the
  app behave as logged in with that client (isLoggedIn true, accounts = [one fake account with that
  viewer], client = given client, no network). Keep it tiny.

### media (ImageLoader, MediaViewer, video)
- **R6 One close button**: `fullScreenCover` on watchOS already draws a system close (X) button.
  Remove MediaViewer's own close button. Add the hand double-tap to close: a real `Button` that calls
  `dismiss()` with `.handGestureShortcut(.primaryAction)`, made invisible (`.opacity(0)`,
  `.frame(width: 1, height: 1)`, `.accessibilityHidden(true)`) — keep it in the view hierarchy.
- **R7 Video**: new `PerchWatch/VideoDownloader.swift` — `@MainActor final class VideoDownloader:
  ObservableObject` with `@Published progress: Double (0…1)`, `@Published bytesPerSecond: Double`,
  `@Published receivedBytes: Int64`, `@Published totalBytes: Int64?`, `@Published fileURL: URL?`,
  `@Published error: String?`, `func start(_ url: URL)`, `func cancel()`. Downloads with
  `URLSession.bytes(for:)` into `Caches/perch-video/<hash>.mp4` (reuse if already complete), updates
  progress at most 4×/s. MediaViewer's video page shows the thumbnail + a thin progress bar and
  "42% · 180 KB/s" (small, centred, bottom) until done, then plays the local file with AVPlayer
  (autoplay). GIFs loop. Use `XMedia.playbackURL(maxBitrate: 0)` semantics = lowest bitrate mp4 (add
  a parameter or pick the min-bitrate mp4 yourself in your file).
- **R8 Zoom**: photos keep Digital Crown zoom (1…5) + drag pan; single tap on the photo toggles
  between 1× and 2.5× (centred). No pinch (MagnifyGesture is unavailable on watchOS).
- **R9 No grey flashes**: (a) `RemoteImage` must show an already-decoded image on its **first frame**:
  look up the memory cache synchronously in `init` (`_image = State(initialValue: …)`). (b) Memory
  cache on watch: 24 MB / 150 items. (c) `ImageLoader.prefetch(_ urls:maxPixel:)` must run at most 3
  downloads concurrently and skip URLs already in memory or on disk. (d) add
  `func prefetchFeed(_ tweets: [XTweet])` that warms, for each tweet's displayed post: author avatar
  (`avatarURL`, maxPixel `Int(44*2.5)`), first media `previewURL` (maxPixel 200) and the exact feed URL
  + maxPixel the feed uses — expose a helper `static func feedImage(for media: XMedia) -> (url: URL, maxPixel: Int)`
  in ImageLoader.swift and make `MediaThumb` (watch-ui) use it, so prefetch and display hit the same key.
  Rule for feedImage: aspectRatio < 0.9 → (`fullURL`, min(1400, Int(450 / max(ratio, 0.3)))), else
  (`feedURL`, 450).

### watch-ui (feed, menu, post, profile)
- **R5 Gestures**: remove `.handGestureShortcut` from the like button (and anywhere else in feed
  rows) so the system double-tap scrolls the feed. Remove the `topID` "isTop" plumbing if unused.
- **R10 Swipe to menu**: root becomes `NavigationStack { TabView(selection:) { MenuPage.tag(0);
  FeedPage.tag(1) }.tabViewStyle(.page(indexDisplayMode: .never)) }` starting on the feed (1).
  Swiping right on the feed reveals the menu; the hamburger button switches to the menu page
  (animated). Menu entries push onto the same NavigationStack. Choosing a timeline or switching
  account returns to the feed page. The menu is no longer a sheet.
- **R11 Action row**: buttons = reply, repost, like, **bookmark** (feed too). **No share button
  anywhere.** All four evenly spaced, icons+counts centred in their quarter.
  Reply = `TextFieldLink` styled like the other glyphs: tapping it opens the keyboard immediately;
  on submit call `client.createTweet(text:replyTo:)`; show a small transient "Sent" / "Failed" label
  (no sheet, no cancel button). Delete `ReplyComposer.swift` and its presentation.
- **R12 Long content**: feed text longer than 280 characters or more than 8 lines is clamped to
  8 lines with a centred-left "Show more" text button under it that expands **in place** (per-post
  `@State`). Absurdly tall images (aspectRatio < 0.45) are scaled to fit a max height of
  `WKInterfaceDevice.current().screenBounds.height * 1.3`, centred, aspect preserved (no crop) —
  normal tall phone screenshots (≥ 0.45) stay full width.
- **R13 Refresh**: (a) after a successful refresh scroll to the first item (set the scroll position
  id to the new first id) — today the stale position id leaves the screen blank with the pull arrow
  stuck; also reset the arrow (`pull = 0`) when a refresh starts and ends. (b) While refreshing or
  loading more, show a slim status line at the top of the feed: `ProgressView` (small) + "Loading
  posts · 85 KB/s" using `TransferMonitor.shared.snapshot()` polled every 0.5 s by a `TimelineView`
  or `Timer` only while loading. Centred, caption2, secondary.
- **R14 Prefetch**: whenever a page of items arrives (refresh, load more, disk seed), call
  `ImageLoader.shared.prefetchFeed(tweets)` for all tweets in it (`item.tweets`, include quoted).
- **R16 Post page**: the focal post is NOT a link to itself (no NavigationLink on its text);
  replies auto-load; the "Load replies" button is shown only when the post's `replyCount > 0`, no
  replies are loaded yet, a cursor exists and nothing is loading — centred. Never show it for 0 replies.
- **R17 Profile**: banner image at the top (full width, 3:1, black when missing), avatar overlapping
  its bottom edge, name, handle, bio, counts row (Posts / Following / Followers) centred, Follow
  button **centred** full-width capsule. Audit every Button on profile/menu/settings/notifications
  for centring.
- **R18 Menu account switch**: picking an account in the account picker closes the picker, returns
  to the feed page and the feed shows For You (core sets the default).
- **R19 Notifications → post**: tapping a notification with a tweet pushes `Route.post(tweet)` (the
  post page; core's R2 removes recommended posts).

### qa (screenshot harness — DEBUG builds and CI only)
- **R20** Debug-only fixture mode: `PerchWatch/Debug/` (whole folder excluded from Release via
  project.yml `EXCLUDED_SOURCE_FILE_NAMES`/conditional sources, or every file wrapped in `#if DEBUG`).
  `FixtureXClient: XClient` serving the JSON in `PerchWatch/Debug/Fixtures/*.json` (copy the mock
  fixtures from `Packages/XKit/Tests/XKitTests/Fixtures/Mock/` and add a v2-style user and a long post
  + a very tall image + a video). Launch arguments: `-PerchFixtures YES` installs it via
  `AppModel.installDebugSession`; `-PerchScreen feed|menu|post|profile|media|notifications|longpost`
  opens that screen directly.
- **R21** New workflow `.github/workflows/screens.yml` (on push to `redesign`, and manual): xcodegen,
  build scheme `PerchWatch` Debug for `platform=watchOS Simulator` (pick the newest available Apple
  Watch Series 10/11 46mm runtime via `xcrun simctl list devices available -j`), boot it, install,
  for each screen launch with the arguments, wait ~6 s, `xcrun simctl io <udid> screenshot
  shots/<screen>.png`, terminate; upload `shots/` as artifact `watch-screens`. Fail the job if the
  build fails; do not fail on a single bad screenshot.

## Ownership

| Agent | Owns |
|---|---|
| core | `Packages/XKit/**`, `Shared/AppModel.swift`, `Shared/Settings.swift` |
| media | `Shared/ImageLoader.swift`, `PerchWatch/MediaViewer.swift`, `PerchWatch/VideoDownloader.swift` (new) |
| watch-ui | all other `PerchWatch/*.swift` (not `Debug/`), `Shared/TweetViews.swift`, `Shared/PagedList.swift`, `Shared/PostStateStore.swift` |
| qa | `PerchWatch/Debug/**`, `project.yml`, `.github/workflows/screens.yml` |

Cross-agent symbols you may call (they are being written in parallel, exactly as named here):
`TransferMonitor.shared.snapshot()`, `TransferMonitor.formatRate(_:)`,
`ImageLoader.shared.prefetchFeed(_:)`, `ImageLoader.feedImage(for:)`, `VideoDownloader`,
`AppModel.installDebugSession(client:viewer:)`.
