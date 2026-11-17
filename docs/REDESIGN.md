# Perch redesign — shared spec (2026-11-17)

Everyone working on this redesign codes against THIS file. If you need an interface that is not
here, do not invent a cross-module one: write a `// TODO(contract): …` comment and mention it in
your final report.

## Hard constraints (read first)

- **There is no Swift compiler on this machine.** Code is only compiled by GitHub Actions
  (Xcode 26.6, iOS SDK 26.x / watchOS SDK 26.5). Every compile error costs a ~10 min CI round
  trip, so write conservative, boring Swift. Re-read every file you change before finishing.
  Check every API you use exists on **watchOS 11 / iOS 18** (deployment targets). If unsure,
  wrap with `if #available(watchOS 26, *)` or don't use it.
- Swift language mode 5, `SWIFT_STRICT_CONCURRENCY: minimal`. UI types are `@MainActor`.
- `XKit` is a Swift package that must also build on Linux (`swift test` runs in CI on macOS, but
  keep `#if canImport(...)` guards that already exist). No SwiftUI/UIKit/WatchKit in XKit.
- Do not touch files outside your ownership list (see "Work split"). Shared files get merged by
  the integrator.
- Do not run `git push`. Commit in your worktree when done (`git add -A && git commit`).
- Never log or print cookie/token values. Use `Redactor` when logging.
- Account safety rules from docs/PLAN.md still apply (rate limiter, no polling < 15 min).

## Product goals (from the user, verbatim intent)

1. No sound and no vibration when refreshing posts (remove `Haptics.*` from refresh/sync paths).
2. Setting "Refresh when opening the app" (default ON). When OFF the app shows the cached feed and
   only refreshes on pull-to-refresh.
3. Pure black background. No grey cards/platters around posts (watchOS `List` draws platters → the
   feed uses `ScrollView` + `LazyVStack`, background `Color.black`).
4. No Following/For You buttons at the top. A **hamburger button** (top-left toolbar,
   `line.3.horizontal`, round like the system toolbar buttons) replaces the settings icon and opens
   the **Menu**, where the timeline is switched.
5. Big, readable posts in the style of the "Parrot for Twitter" Watch app (reference screenshots):
   - Header: avatar **44 pt** circle, then name (bold, ~17 pt, 1 line) + verified seal, and below
     `@handle · 2h` (secondary, ~15 pt).
   - Body text `.system(size: 19)` (≈ Parrot), white, full width, no line limit in the feed.
   - Media: **full width of the screen**, aspect ratio preserved, **no max height cap** (a tall
     screenshot is shown full height and you scroll past it), corner radius 12. Videos/GIFs show the
     thumbnail with a large white ▶ circle (`play.circle` ~ 44 pt) centred.
   - Action row under each post: reply (`bubble.left` + count), repost (`arrow.2.squarepath` +
     count), like (`heart` + count), share (`square.and.arrow.up`), evenly spaced, ~16 pt, secondary
     colour; active like = pink filled heart, active repost = green.
   - Thin separator (`Color.white.opacity(0.15)`, 0.5 pt) between posts. Horizontal padding ≈ 4 pt.
   - Retweet banner above the header ("X reposted", secondary, small).
6. Video playback must work (full screen, with sound).
7. Tapping an image or video in the feed opens it **full screen** (media viewer), NOT the post page.
   Tapping elsewhere on the post opens the post page.
8. Tapping a profile photo or name opens that user's **full profile in a popup sheet** (banner,
   avatar, name, handle, bio, followers/following/posts counts, **Follow / Following button**, and
   their recent posts with infinite scroll).
9. Post page: replies **auto-load** when scrolling near the bottom (no "Load more" button needed).
10. Menu also offers **Likes** (the active account's liked posts) and **Bookmarks**, and
    **Notifications** (with unread badge).
11. Multi-account: accounts are added on the iPhone (several X logins) and all are synced to the
    Watch. Menu row #1 = active account (avatar + name + @handle + a `person.2.circle` "switch"
    symbol). Tapping **anywhere on that row** opens a popup listing all accounts; tapping one
    switches. Each device keeps its own active account (independent).
12. Caching + background refresh (~every 30 min) of the feed, without hurting battery.
13. Load posts as fast as possible: show disk cache instantly, low-res image first then full res,
    prefetch next page early.
14. Extras approved by the user: working action buttons (like/repost/bookmark/reply by dictation/
    share), watch-face **complication**, **double-tap gesture to like**, Notifications in menu,
    **follow/unfollow** from a profile.

## Contracts

### XKit (owner: `core`)

```swift
public struct XAccount: Codable, Sendable, Hashable, Identifiable {
    public var id: String              // numeric X user id (credentials.userId) or "local-<8 hex of sha256(authToken)>"
    public var credentials: XCredentials
    public var user: XUser?            // cached profile (name, handle, avatar) for the account pickers
    public init(credentials: XCredentials, user: XUser? = nil)
    public static func id(for c: XCredentials) -> String
}

public actor XSessionStore {
    // existing API stays (credentials, config, material, setCredentials, updateCt0, wipe, observe…)
    public private(set) var accounts: [XAccount]
    public private(set) var activeAccountId: String?
    public var activeAccount: XAccount? { get }
    /// `credentials` == active account's credentials (nil when no accounts).
    @discardableResult public func upsertAccount(_ c: XCredentials, user: XUser?) -> String // returns id, makes it active
    public func setActiveAccount(_ id: String)
    public func removeAccount(_ id: String)          // if active, next account becomes active (or none)
    public func replaceAccounts(_ list: [XAccount])  // used by the Watch on sync; keeps current active if still present, else first
    public func updateUser(_ user: XUser, forAccount id: String)
    // setCredentials(c) updates the ACTIVE account's credentials (ct0 rotation) or upserts if none.
}
```
- Keychain: all accounts as one JSON blob under account key `"x-accounts"`, active id under
  `"x-active"`. On first launch migrate the legacy single `"x-session"` credentials into the list
  (then delete `"x-session"`).
- `SyncPayload` gains `public var accounts: [XAccount]?` (Codable optional ⇒ old payloads decode).
  `.update` with `accounts != nil` → `store.replaceAccounts(accounts)`; with only `credentials` →
  `upsertAccount`. `.logout` wipes everything (all accounts). An empty `accounts` list = logged out.
- `Operation.likes = "Likes"`; `LiveXClient.likes(userId:cursor:) -> TimelinePage` (and in the
  `XClient` protocol). Variables like web: `userId`, `count`, `includePromotedContent:false`,
  `withClientEventToken:false`, `withBirdwatchNotes:false`, `withVoice:true`. Add `"Likes"` to
  `scripts/update_endpoints.py` OPERATIONS and add its queryId/features to BOTH endpoints.json
  copies (run `python3 scripts/update_endpoints.py`; it only needs the network).
- `XMedia` helpers:
  - `public var previewURL: URL` → `imageURL(size: "240x240")` (tiny, used as the low-res first pass)
  - `public var feedURL: URL` → `imageURL(size: "small")` (680 px, used in the feed)
  - `public var fullURL: URL` → `imageURL(size: "medium")`
  - `public func playbackURL(maxBitrate: Int = 900_000) -> URL?` → best `video/mp4` variant with
    bitrate ≤ maxBitrate (else the lowest-bitrate mp4, else the HLS `application/x-mpegURL` one).
    GIFs (`animated_gif`) have one mp4 variant with bitrate 0 — return it.
- Unit tests for: account migration/upsert/remove/replace, SyncPayload round-trip with accounts and
  decoding an old payload without `accounts`, `playbackURL` selection.

### AppModel (owner: `core`) — `Shared/AppModel.swift`

```swift
@Published private(set) var accounts: [XAccount]
@Published private(set) var activeAccountId: String?
var activeAccount: XAccount? { get }
func switchAccount(to id: String) async   // rebuild client, clear viewer/badge/post overrides, reload state
func login(_ creds: XCredentials) async    // upsert + make active (iPhone), then fetch viewer & store it in the account
func removeAccount(_ id: String, propagate: Bool = true) async
func logout(propagate: Bool = true) async  // removes ALL accounts (existing semantics)
func timelineCacheName(_ kind: HomeKind) -> String   // "home-\(activeAccountId ?? "none")-\(kind.rawValue)"
```
- `loadViewer()` stores the fetched `XUser` into the active account (`store.updateUser`), so pickers
  show avatars/names.
- `TimelineDiskCache.clear()` must clear all `perch-home-*` files.

### Settings keys — `Shared/Settings.swift` (owner: `core`, create it)

```swift
enum PerchSettings {
    static let autoRefreshOnOpen = "autoRefreshOnOpen"   // Bool, default true (register default)
    static let homeKind = "homeKind"                     // String HomeKind rawValue (already used)
    static func registerDefaults()                       // call from both App inits
}
```

### Routes — `Shared/TweetViews.swift` `enum Route` (owner: `watch-ui`)
Add `case likes`. Keep existing cases (iOS uses some).

### Media (owner: `media`)
- `RemoteImage(url: URL?, placeholderURL: URL? = nil, maxPixel: Int = 300, contentMode: ContentMode = .fill)`
  — shows `placeholderURL` (tiny, blurred) until `url` is loaded; keep the existing init signature
  working (new param defaulted).
- `ImageLoader`: add a disk cache (Caches/perch-img, LRU ~60 MB on watch / 150 MB iPhone, keyed by
  URL, stores the downloaded bytes) in front of the network; `func prefetch(_ urls: [URL], maxPixel: Int)`
  (low priority, used by background refresh); keep memory cache.
- `struct MediaViewer: View { init(media: [XMedia], startIndex: Int) }` — full screen (presented by
  callers with `.fullScreenCover`), black, swipe horizontally between items (`TabView` page style),
  photos: crown zoom + drag pan + double-tap reset (reuse/replace `ImageZoomView`), videos/GIFs:
  `VideoPlayer(player:)` from AVKit with `AVPlayer(url: media.playbackURL())`, autoplay on appear,
  pause on disappear, GIFs loop muted. Close button top-left. File: `PerchWatch/MediaViewer.swift`.
  Remove `ImageZoomView` from `PostDetailView.swift` ONLY by telling the integrator (that file belongs
  to `watch-ui`); put the new viewer in your file.

### Background + complication (owner: `bg`)
- `PerchWatch/BackgroundRefresh.swift`: `enum BackgroundRefresh { static func schedule(); static func handle() async }`
  - schedule: `WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: now+30min, userInfo: nil)`.
  - handle: skip if not logged in or `ProcessInfo.processInfo.isLowPowerModeEnabled`; fetch first page of
    the active account's current `homeKind` timeline, save to `TimelineDiskCache` under
    `AppModel.shared.timelineCacheName(kind)`, prefetch images of the first 8 posts (feed size), fetch badge
    counts, write complication snapshot to the App Group, `WidgetCenter.shared.reloadAllTimelines()`, then
    `schedule()` again. Hard time budget ~15 s (cancel after).
  - The integrator wires it into `PerchWatchApp` with `.backgroundTask(.appRefresh) { await BackgroundRefresh.handle() }`
    — write the exact snippet in your report.
- Complication = new watchOS WidgetKit extension target `PerchWidget` (folder `PerchWidget/`),
  bundle id `$(PERCH_BUNDLE_ID).watchkitapp.widget`, embedded in `PerchWatch` (edit `project.yml`).
  Families: `.accessoryCircular` (bird + unread count), `.accessoryRectangular` (newest post: author +
  2 lines of text), `.accessoryInline`, `.accessoryCorner`. Tapping opens the app.
  Timeline from the App Group snapshot; refresh policy `.never` (the app reloads it).
- App Group sharing: `Shared/AppGroup.swift` — resolve the group id at runtime because the sideload
  signer may rewrite bundle ids: candidates = Info.plist key `PerchAppGroup` (set to
  `group.$(PERCH_BUNDLE_ID)` in project.yml), then `"group." + <own bundle id without .watchkitapp/.widget suffixes>`.
  First candidate whose `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` is non-nil wins;
  if none, fall back to UserDefaults.standard (complication then just shows the bird). Entitlements files
  for PerchWatch and PerchWidget with `com.apple.security.application-groups = [group.$(PERCH_BUNDLE_ID)]`.
- The snapshot struct: `struct ComplicationSnapshot: Codable { var unread: Int; var author: String?; var text: String?; var updated: Date }`.

### Watch UI (owner: `watch-ui`)
Files: `PerchWatch/HomeView.swift`, `PerchWatch/PerchWatchApp.swift` (root view + menu + routes,
NOT the `App` scene modifiers — leave `PerchWatchApp: App` body as is apart from what you must),
`PerchWatch/PostDetailView.swift`, `PerchWatch/WatchSettingsView.swift`, `PerchWatch/PullToRefresh.swift`,
`Shared/TweetViews.swift`, `Shared/PagedList.swift`, `Shared/PostStateStore.swift`, new files under
`PerchWatch/` (MenuView, ProfileSheet, AccountPicker, NotificationsView, TimelineListView, ReplyComposer …).
- Use `RemoteImage(url: m.feedURL, placeholderURL: m.previewURL, maxPixel: 450)` in the feed and
  present `MediaViewer(media:startIndex:)` with `.fullScreenCover` on media tap.
- `TweetViews.swift` is shared with the iOS app; keep iOS compiling (watch-only styling via `#if os(watchOS)` / `Metrics`).
- Double-tap: attach `.handGestureShortcut(.primaryAction)` (watchOS 11) to the like button of the
  post currently at the top of the viewport only (track with `.scrollPosition(id:)` on the
  `LazyVStack` items), so the gesture likes the post you are reading.
- Reply: a sheet with `TextField` (watchOS shows dictation/scribble) → `client.createTweet(text:replyTo:)`.
- Share: `ShareLink(item: URL(string: "https://x.com/\(handle)/status/\(id)")!)`.
- Remove all haptics from refresh/sync paths (PullToRefresh, WatchSync apply — tell the integrator about
  WatchSync, it belongs to `core`). Keep the existing subtle haptic for explicit taps (like/repost) and
  `Haptics.failure()` on errors.
- "Refresh when opening the app" toggle in WatchSettingsView bound to `@AppStorage(PerchSettings.autoRefreshOnOpen)`.
  HomeView: on appear, seed from disk cache; only call `refresh()` if the setting is on OR the cache is empty.
- PagedList: prefetch next page when within 8 items of the end.

### iOS app (owner: `ios`)
Files: `Perch/*` only. Account list section: each account (avatar, name, @handle, active checkmark),
tap = make active on iPhone, swipe to delete (`app.removeAccount`), "Add account" button opens the
existing login sheet. **Before each new web login, clear the WKWebView cookies for x.com/twitter.com**
(`WKWebsiteDataStore.default().removeData(...)`) so the previous account's session is not reused; after
capturing cookies, clear them again. Manual cookie paste also adds an account. After any change call
`sync?.syncNow()` (PhoneSync must send ALL accounts — PhoneSync is owned by `core`).

## Work split / ownership

| Agent | Owns |
|---|---|
| core | `Packages/XKit/**`, `Shared/AppModel.swift`, `Shared/Settings.swift` (new), `Perch/PhoneSync.swift`, `PerchWatch/WatchSync.swift`, `scripts/update_endpoints.py`, `endpoints.json` |
| media | `Shared/ImageLoader.swift`, `PerchWatch/MediaViewer.swift` (new) |
| watch-ui | listed above |
| bg | `PerchWatch/BackgroundRefresh.swift`, `Shared/AppGroup.swift`, `PerchWidget/**`, `project.yml`, entitlements files |
| ios | `Perch/*` except `PhoneSync.swift` |

Integrator (Claude) merges, resolves conflicts, wires snippets and fixes CI.
