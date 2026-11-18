# Brief: crown-lab — measure Digital Crown routing in the watchOS simulator (NO app behaviour change)

Repo worktree: `~/perch-wt/crown-lab`, branch `crown-lab` (from `redesign@e7cdf0c`). Read first:
`~/perch-review/crown-plan.md` (the audit + research), `PerchWatch/PerchWatchApp.swift` (RootPager),
`PerchWatch/HomeView.swift`, `PerchWatch/MenuView.swift`, `PerchWatch/FeedPostView.swift` (MediaPresenter/MediaHost),
`PerchWatch/MediaViewer.swift`, `PerchWatch/SwipeBack.swift`, `PerchWatch/Debug/*` (fixture harness),
`project.yml` (XcodeGen), `.github/workflows/screens.yml`.

## Goal
A pass/fail table that says, for each scenario, whether turning the Digital Crown (with NO touch after the
scenario's steps) scrolls the list that is on screen. Run on the CURRENT code. Do not fix anything.

## Facts (researched; do not re-derive)
- `XCUIDevice.shared.rotateDigitalCrown(delta:)` / `rotateDigitalCrown(delta:withVelocity:)` exists in XCTest for
  watchOS (Xcode 13+, WWDC21 "Explore UI testing enhancements"). Crown scrolling is non-inertial: content moves
  only while rotating.
- watchOS gives the crown to one scrollable at a time. A finger touch on a scroll view gives it the crown, so a
  scenario must not touch the list after its last navigation step before rotating.
- There is no Swift compiler on this machine. CI (macos-26, Xcode 26.6) is the only compiler. Be extremely careful
  with syntax/availability (watchOS 11 deployment target). Re-read every changed file for compile errors.

## Deliverables
1. **DEBUG-only scroll probe** (`PerchWatch/Debug/CrownProbe.swift`, file wrapped in `#if DEBUG`): a modifier
   `.crownProbe("name")` that reports the scroll view's `contentOffset.y` (via `onScrollGeometryChange`) as the
   `accessibilityValue` of an invisible element with identifier `probe.<name>`. It must NOT be focusable, must not
   take hits (`allowsHitTesting(false)`), must not change layout, and must not add `.focusable`, `@FocusState`,
   `.disabled` or gestures. In Release the modifier is a no-op: define it as `#if DEBUG ... #else` returning `self`
   in a non-Debug file (e.g. `PerchWatch/LayoutProbe.swift` pattern — copy how `.layoutProbe` is done).
   Attach it to: the 2 `HomeView` scroll views (`feed.forYou`, `feed.following` — use `kind`), the menu `List`
   (`menu`), `PostDetailView` (`post`), `TimelineListView` (`likes`/`bookmarks`), `ProfileSheet` scroll view
   (`profile`), `NotificationsView`, `SavedView`, `SearchView`, `UserFeedView`, `WatchSettingsView`.
   Also give the tappable things the tests need stable `accessibilityIdentifier`s ONLY if they have none
   (e.g. first post row, media tile, back/close buttons). Identifiers only, no behaviour change.
2. **UI test target** `PerchWatchUITests` in `project.yml`: `type: bundle.ui-testing`, `platform: watchOS`,
   `TEST_TARGET_NAME: PerchWatch`, dependency on PerchWatch, Debug only, plus a scheme that can run it
   (add it to the PerchWatch scheme's test targets, or a dedicated `PerchWatchCrown` scheme). Check how the
   project is generated in CI (XcodeGen step in the workflows) and keep the iOS `Build` workflow unaffected.
3. **Tests** `PerchWatchUITests/CrownRoutingTests.swift`. Launch args `-PerchFixtures YES` (real root, fixture
   timeline). Helper: `crownScrolls(probe:) -> Bool` = read value, `rotateDigitalCrown(delta: 0.5)` a few times,
   wait ~1 s, read again, pass if it moved >= 20 pt. Scenarios (one test method each; each runs 3 iterations
   from a fresh launch and records k/3 — the user sees intermittent failures):
   - S1 cold launch, wait for the intro to finish (~3 s), crown on `feed.forYou`.
   - S2 swipe left (For You -> Following), crown on `feed.following`.
   - S3 S2 then swipe right back, crown on `feed.forYou`.
   - S4 swipe right to menu, crown on `menu`; S5 then hamburger/back button to feed.
   - S6 hamburger button -> menu -> crown; S7 tap menu row Likes (push) -> crown on `likes`; S8 back button -> crown on `menu`.
   - S9 tap a post -> crown on `post`; S10 back via back button -> `feed.forYou`; S11 back via swipe right -> `feed.forYou`.
   - S12 tap a photo tile -> crown in viewer (zoom; just record) -> close button -> crown on `feed.forYou`.
   - S13 same with a GIF and S14 with a video if fixtures have them (skip with a note if not).
   - S15 tap an avatar -> profile sheet -> crown on `profile`; S16 close sheet -> crown on `feed.forYou`.
   - S17 crown-refresh at top (rotate up a lot) then crown down on `feed.forYou`.
   Use waits for elements, not fixed sleeps, except the ~1 s settle after navigation (document it).
4. **CI**: in `.github/workflows/screens.yml` add `crown-lab` to the push branches and a step after
   Screenshots that runs `xcodebuild test` for the UI tests on the same simulator with
   `-resultBundlePath build/crown.xcresult`, `continue-on-error: true` (failures are the data), then writes a
   markdown table (scenario, k/3, notes) to `$GITHUB_STEP_SUMMARY` and uploads `crown-report` (table + xcresult).
   Use `xcrun xcresulttool` or print lines from the tests themselves (`print("CROWN S2 1/3 ...")`) and grep the log.
5. Commit on `crown-lab` and push `git push -u origin crown-lab`. Watch the run with
   `gh run list -R ICoolBuddy/Twitter-for-WatchOS -b crown-lab` / `gh run view --log-failed`; fix compile/CI
   errors until the job produces the table (test failures are fine, build failures are not). Max 6 CI rounds;
   then stop and report what blocks you.

## Hard rules
- No change to app behaviour: only DEBUG probe code, accessibility identifiers, the test target, CI.
- Do not touch `redesign`, do not merge, do not install on devices.
- No guessing: if an API is uncertain, say so in the report and design the test so CI proves it.

## Report
Write `~/perch-review/reports/crown-lab.md`: files changed, the CI run id, the full scenario table, anything
skipped and why, and any sign the probe/test itself could affect focus. End with `AGENT-DONE crown-lab`.
