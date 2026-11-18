# Digital Crown audit + plan (2026-11-18, base `e7cdf0c`)

## How watchOS routes the crown (what we rely on)
- The crown drives exactly ONE scrollable at a time (the focused one).
- The system picks it at its own re-evaluation points (screen appears, presentation
  changes) and whenever the user *touches* a scroll view. A touch always works ->
  "dead until I scroll with my finger" = nothing is focused, or the wrong view is.
- Changing `.offset` or toggling `.disabled` does NOT obviously trigger a re-evaluation.
  Removing or disabling the focused view leaves focus empty. (Unverified hypothesis:
  phase 1 proves or refutes it.)
- Explicit `@FocusState`/`.focusable()` on a plain ScrollView suppresses native
  routing (Hello Weather post-mortem; our own 8 failed rounds).

## Every place the crown can get lost (from the code)
| # | Place | Code | Suspected mechanism |
|---|-------|------|---------------------|
| H1 | Swipe For You <-> Following, menu <-> feed, hamburger | `RootPager` (PerchWatchApp.swift:195): 3 live scrollables (Menu `List`, 2x `HomeView` ScrollView) side by side in an HStack moved by `.offset`; off-screen ones `.disabled(page != n)` | Focused page becomes disabled; the newly enabled page is never re-chosen -> no owner until touch. |
| H2 | Cold launch | Same 3 scrollables appear at once; `LaunchIntroView` overlay on top | First choice may land on an off-screen/disabled page or happen under the intro. |
| H3 | Back from a pushed screen (post, profile, likes, bookmarks, saved, search, notifications, settings) | `NavigationStack(path:)` + `SwipeBack` (custom offset drag + `nav.back()`) | Focused scroll view is removed; root pager has 3 candidates, 2 disabled -> may not re-pick. |
| H4 | After closing photo/GIF/video | `MediaHost` overlay in a ZStack above the NavigationStack (not a real presentation); viewer pages use `.focusable/.focused` + `digitalCrownRotation`; video uses `WKInterfaceVolumeControl.focus()` | Viewer explicitly owns focus, then is removed; nothing underneath re-claims because no presentation change happened. |
| H5 | Inside the profile sheet / after it closes | `.sheet` + own `NavigationStack` + its own `MediaHost` | Same as H3/H4 inside the sheet. |
| H6 | Account picker / menu interactions | `MenuView` sheet + `List` on page 0 | Same as H3 after dismissal. |
| H7 | Pull-to-refresh / crown refresh | `PullToRefresh`: `proxy.scrollTo` + scroll geometry tracking | Likely fine (scroll view persists); verify only. |

## Plan
### Phase 1 - measure, don't guess (no app behaviour change)
- Add a watchOS **UI test target** (`PerchWatchUITests`) run in the existing
  `Watch screens` CI job on the simulator with the fixture data.
- Each scenario: launch with fixtures, do the steps, then
  `XCUIDevice.shared.rotateDigitalCrown(delta:)` **without touching**, and assert
  the visible list moved (a DEBUG-only accessibility probe exposes the content offset
  of each scroll view).
- Scenarios: cold launch; swipe For You->Following, back; ->menu, back; hamburger;
  push post + back (button and swipe); push likes + back; open/close photo, GIF, video;
  open/close profile sheet; account picker; after refresh.
- Output: a pass/fail table on `e7cdf0c`. The device matters most, so the table is
  checked against what you see on the Watch.

### Phase 2 - spikes, each judged by the phase-1 test
- **A. Native pager:** `TabView` `.page` style (system-managed paging = system-managed
  crown hand-off). Must also re-test the old "black screen after swipe-pop" bug that
  made us drop TabView (possible fix: NavigationStack per page, or a different nesting).
- **B. One live scrollable:** only the visible page is an enabled scroll view; off-screen
  pages are taken out of the focus tree entirely (not just `.disabled`), with the
  scroll position kept.
- **C. Media viewer as a real presentation** (`fullScreenCover` with hidden chrome)
  instead of a ZStack overlay, so dismissal is a presentation change the system
  re-evaluates on.
- Winner = the smallest change that passes every scenario.

### Phase 3 - implement + verify
- opencode agent(s) with a spec + acceptance = the phase-1 test green.
- Claude reviews the diff, CI green, install with `perch-sideload wsign`, then you
  test on the Watch with a crown-only checklist.

## Research log (2026-11-18 ~12:40)
- Hello Weather post-mortem (trevorturk.github.io/deleting-the-workarounds): crown dead until finger drag; causes =
  nested/competing scrollables (crown binds to ONE scrollable) + explicit focus code suppressing native routing.
  Final structure: native horizontal ScrollView with `.scrollDisabled(true)` "paged by tap and swipe" (2026-08-15);
  where scrollDisabled sits / crown hand-off after a page change is NOT stated. Simulator reproduces crown bugs.
- Apple (WWDC23 10031/10138): watchOS 10+ top-level paging = `TabView` `.verticalPage`; crown navigates tabs and
  scrolls inside a tab ("TabView will designate one tab to its child List view"). Horizontal `.page` not recommended
  in those sessions. NO Apple source documents when the system re-picks the crown target, or what happens when the
  focused view is disabled/removed, after push/pop, or after dismissals -> must be measured.
- Focus-engine skill (mhaviv): List/ScrollView get the crown automatically, no focus modifiers; nothing on
  multiple scrollables or disabled/removed focus.
- Apple forums 683806 / 717640: devs report focus lost after TabView page swipes; no Apple answer.
- XCUIDevice.rotateDigitalCrown(delta:velocity:) works in watchOS UI tests (WWDC21 10208), non-inertial.
=> Phase 1 (crown-lab) brief: ~/perch-review/briefs/crown-lab.md

## User answers (2026-11-18 ~12:50)
- Crown also dies right after TAPPING BUTTONS: the media viewer's X (close) button and the hamburger button
  (works again after a finger scroll). Also after leaving Bookmarks, Likes, profile, post detail, full-screen
  photo/GIF/video. => add scenarios: tap hamburger -> crown; tap X close -> crown; back from bookmarks/likes/profile/post.
  Hypothesis to test: a tapped Button takes crown focus / focus moves to the tapped control and stays there.
- Pager: "whatever makes the result work" -> free choice (horizontal rebuild or vertical pages), decided by the tests.
- DECIDED (user, ~12:55): KEEP HORIZONTAL paging (no verticalPage). Install on devices only once the simulator
  tests show everything fixed (no interim installs). No other crown-dead places seen beyond the above.
