# crown-lab — Digital Crown routing measurements (watchOS simulator)

Status: in progress — CI round 1 running (branch `crown-lab`, base `e7cdf0c`).

## What this is

Phase 1 of `~/perch-review/crown-plan.md`: for each of the brief's scenarios, does
turning the Digital Crown — **with no touch after the scenario's last navigation
step** — scroll the list that is on screen? Measured only; nothing was fixed.

## Files changed

| File | Change |
|---|---|
| `PerchWatch/Debug/CrownProbe.swift` | **new**, `#if DEBUG` only: `.crownProbe("name")` republishes `ScrollGeometry.contentOffset.y` (plus content/viewport height) as the `accessibilityValue` of an invisible `probe.<name>` element |
| `PerchWatch/LayoutProbe.swift` | the `.crownProbe` extension in a non-Debug file, same shape as `.layoutProbe`: `#if DEBUG modifier(...) #else self` — a no-op in Release |
| `PerchWatch/HomeView.swift` | probe on both feed scroll views (`feed.forYou`, `feed.following`, by `kind`) |
| `PerchWatch/MenuView.swift` | probe on the menu `List` (`menu`); ids `menu.notifications`, `menu.likes` |
| `PerchWatch/PostDetailView.swift` | probe (`post`) |
| `PerchWatch/TimelineListView.swift` | probe (`likes` / `bookmarks` from `kind.rawValue`) |
| `PerchWatch/ProfileSheet.swift` | probe on `ProfileContent`'s scroll view (`profile`); id `sheet.close` |
| `PerchWatch/NotificationsView.swift` | probe (`notifications`) |
| `PerchWatch/SavedView.swift` | probe (`saved`) |
| `PerchWatch/SearchView.swift` | probe (`search`) |
| `PerchWatch/UserFeedView.swift` | probe (`userfeed`) |
| `PerchWatch/WatchSettingsView.swift` | probe (`settings`) |
| `PerchWatch/FeedPostView.swift` | ids only: `post.open.<tweetId>` (text link), `media.tile.<tweetId>.<index>`, `avatar.<tweetId>` |
| `PerchWatch/PerchWatchApp.swift` | id `chrome.menuToggle` on the leading toolbar button (hamburger / back to feed) |
| `PerchWatch/MediaViewer.swift` | id `media.close` on the viewer's close button |
| `project.yml` | `PerchWatchUITests` (`type: bundle.ui-testing`, `platform: watchOS`, `TEST_TARGET_NAME: PerchWatch`, dependency on PerchWatch, generated plist) + the `PerchWatchCrown` scheme (test action in Debug); `CrownProbe.swift` added to the Release `EXCLUDED_SOURCE_FILE_NAMES` |
| `PerchWatchUITests/CrownRoutingTests.swift` | **new**: 18 scenarios, 3 cold launches each |
| `.github/workflows/screens.yml` | `crown-lab` added to the push branches; "Crown routing UI tests" (`xcodebuild test`, `continue-on-error`), "Crown routing table" (markdown to `$GITHUB_STEP_SUMMARY`), "Upload crown report" steps |

App behaviour: no change. Everything new in the app is a DEBUG-only probe, an
`accessibilityIdentifier`, or the test target. Release builds compile `crownProbe`
to `self` and never see `CrownProbe.swift` (file-level `#if DEBUG` *and* excluded
from the Release target).

### How the probe reads the offset, and why it should not touch focus

- `onScrollGeometryChange(for:of:action:)` is the same API `PullToRefresh` already
  uses on this target (watchOS 11). The value is stored in a class box
  (`CrownProbeBox`, the `OverscrollTracker` pattern) so a scroll frame re-renders
  only the marker, never the scroll view it measures.
- The marker is a `Text(verbatim: "crown")` at 1 pt, clear foreground, 1×1 frame,
  clipped, in an `.overlay(alignment: .topLeading)` — an overlay adds no layout,
  and a `Text` is guaranteed to be an accessibility element (a `Color.clear` is
  not; that is why the marker is not one).
- No `.focusable()`, no `@FocusState`, no `.disabled`, no gesture, and
  `allowsHitTesting(false)` on the marker: nothing here can take the crown, take a
  tap, or make watchOS re-evaluate crown ownership. This is the one class of thing
  the audit says *does* kill routing, so it was avoided deliberately.
- Value format `y=<offset> h=<content> v=<viewport>`: `y` is the number the test
  reads; `h`/`v` let a "did not move" row say whether the list had room to move
  (an empty Likes fixture cannot scroll at all).

## Scenarios (as implemented)

| id | steps | probe |
|---|---|---|
| S1 | cold launch, intro gone (element wait + the intro's own 3 s maximum), no touch | `feed.forYou` |
| S2 | swipe left (For You → Following) | `feed.following` |
| S3 | S2, then swipe right back | `feed.forYou` |
| S4 | swipe right from For You → menu | `menu` |
| S5 | S4, then the leading toolbar button back to the feed | `feed.forYou` |
| S6 | hamburger button → menu | `menu` |
| S7 | S6, then the Likes row (push) | `likes` |
| S7b (added) | S6, then the Notifications row (push) — Likes' fixture list is empty, so this measures the same push with rows | `notifications` |
| S8 | S7, then the back button | `menu` |
| S9 | tap the first post's text link (push) | `post` |
| S10 | S9, then the back button | `feed.forYou` |
| S11 | S9, then a mid-screen swipe right (SwipeBack) | `feed.forYou` |
| S12 | tap the first post's photo tile → viewer → (crown there zooms: recorded) → close button | `feed.forYou` |
| S13 | same with a GIF | — (skipped: no GIF fixture) |
| S14 | same with the video in the fixture timeline (scrolled into reach first) | `feed.forYou` |
| S15 | tap the first post's avatar → profile sheet | `profile` |
| S16 | S15, then the sheet's Close button | `feed.forYou` |
| S17 | at the top: crown up ×10, then crown down ×4 (refresh pill recorded) | `feed.forYou` |

Method per attempt: launch (`-PerchFixtures YES -homeKind forYou`), run the steps,
**one** documented 1 s settle after the last navigation step, read `probe.<name>`,
`XCUIDevice.shared.rotateDigitalCrown(delta: 0.5)` ×4 with no touch, 1 s settle,
read again; `MOVED` when `|Δy| ≥ 20 pt`. Every navigation step is verified before
measuring (page on screen from the probe's x, pushed screen from the probe's
existence), and a failed step is reported as `BLOCKED`, never as `STILL` — a broken
tap must not look like a crown bug.

`-homeKind forYou` is a UserDefaults launch argument (argument domain), not app
code: swiping to Following writes `homeKind`, and every scenario has to start on
For You.

## Results

CI run: pending.

## Skipped / not measured

- **S13 (GIF)**: `home_timeline.json` has photos and one video, no GIF. Reported as
  `SKIPPED` with that note.
- **S12/S14 in-viewer crown**: the photo/video pages use `digitalCrownRotation` on
  a `focusable` page, not a scroll view, so there is no scroll offset to probe; the
  scenarios record that the viewer opened and assert only the state after closing.
- **S7 (Likes)**: the fixture Likes timeline is empty (`FixtureXClient.likes`
  returns no items). A list with less content than the viewport cannot scroll, so
  that row can only say whether the crown reaches the pushed `likes` scroll view at
  all; S7b does the same push on Notifications, which has fixture rows.

## Uncertainties (design assumes, CI proves)

1. `XCUIDevice.shared.rotateDigitalCrown(delta:)` — per the brief (and WWDC21
   session 10208) this is the watchOS UI-test API; there is no Swift compiler on
   this machine, so the first CI build is its compile check.
2. The probe element: a 1 pt clear `Text` in an overlay is assumed to be exposed to
   XCUITest with our `accessibilityValue`. If it is not, every row reports
   `NOPROBE` (loudly, in the table) rather than a false `STILL`.
3. The pushed screen's back chevron is watchOS' own control (no identifier we can
   set). The test tries the `Back` label, then any navigation-bar button in the
   left 40 %, then a coordinate; every use reports which path worked, and the
   scenario verifies the pop happened.
4. Whether the simulator reproduces device crown routing — that is what the table
   is for.

AGENT-DONE crown-lab
