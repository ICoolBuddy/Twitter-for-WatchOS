# Crown fix — handoff (2026-11-18 13:00, laptop battery died)

Continue from here (cloud session OK; device install needs the laptop).

## Problem
Crown scrolling dead until a finger scroll: after swiping For You <-> Following, after tapping the
hamburger button or the media viewer's X, after leaving Bookmarks / Likes / profile / post detail /
full-screen photo-GIF-video. Installed build on devices: `e7cdf0c` (redesign).

## Done
- Audit + research: `docs/crown/PLAN.md` (every suspect place, sources, plan).
- Phase 1 (measure, no behaviour change) on branch `crown-lab`: DEBUG-only `.crownProbe` on every scroll
  view + UI test target `PerchWatchUITests` (scheme `PerchWatchCrown`, `CrownRoutingTests.swift`) that turns
  the crown with XCUIDevice.rotateDigitalCrown and checks the visible list moved; runs in `Watch screens` CI.
  Commits `a2a14ab`, `c15e552`. CI run 44288786523 was the first real test run — READ ITS STEP SUMMARY /
  `crown-report` artifact first.

## User decisions
- Keep HORIZONTAL paging (no verticalPage). Rebuild the pager however needed, same look/feel.
- Install on iPhone+Watch only after the simulator tests show every scenario fixed (no interim installs).
- No other dead-crown places seen beyond the list above.
- Work style: clear spec, opencode agents (laptop) or direct; research, don't guess; verify in CI.

## Next steps
1. Read run 44288786523 results; fix the test harness if it didn't produce the table.
2. Add scenarios: tap hamburger -> crown; tap media X -> crown; back from bookmarks/likes/profile/post/GIF/video.
3. Pass/fail table on e7cdf0c = baseline.
4. Fix (candidates in PLAN.md phase 2: one live scrollable / native horizontal ScrollView pager; media viewer as
   a real presentation; check whether tapped Buttons keep crown focus). Smallest change passing all scenarios.
5. Merge into `redesign`, CI green, then on the laptop: `perch-sideload fetch` (check run id vs git log) and
   `perch-sideload wsign`. Signature expires 2026-11-25.
