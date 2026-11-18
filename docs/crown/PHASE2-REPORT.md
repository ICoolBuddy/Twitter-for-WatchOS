# Crown fix — phase 2 report (2026-11-18)

Continues `HANDOFF.md`. All numbers are from the watchOS 26.5 simulator (Apple Watch Series 11
46 mm, Xcode 26.6) with the DEBUG fixture session, measured by `PerchWatchUITests/CrownRoutingTests.swift`:
"after the last navigation step, with no touch, does turning the crown scroll the list on screen".

## Baseline (shipped code `e7cdf0c`, run 44290934131, 3 cold launches each)

| Scenario | k/3 |
|---|---|
| S1 cold launch → For You | ✅ 3/3 |
| S2 swipe → Following | ❌ 0/3 |
| S3 Following → swipe back | ❌ 0/3 |
| S4 swipe → menu | ✅ 3/3 |
| S5 menu → toolbar button → feed | ❌ 0/3 |
| S6 hamburger → menu | ✅ 3/3 |
| S10 post → Back button | ❌ 0/3 |
| S11 post → swipe back | ❌ 0/3 |
| S15 profile sheet | ✅ 3/3 |
| S16 profile sheet → Close | ❌ 0/3 |
| S17 crown at the top, then down | ✅ 3/3 |
| S7/S7b/S8 menu pushes, S12/S14 media | blocked by the harness (fixed in round 2) |

Pattern: the feed's `ScrollView` got the crown only on its first appearance; every time it became
the visible scroll view again (page swipe, toolbar button, pop, sheet dismissal) the crown went
nowhere. The menu's `List` did get it on each page change.

## Round 1 — one CI job per experiment (run 44294205953, 2 cold launches each)

Experiments live in `PerchWatch/CrownLab.swift` (DEBUG `-crownVariant`; Release = shipped code):
P = only the visible pager page in the view tree at rest; S = `.scrollDisabled` instead of
`.disabled`; T = system `TabView(.page)` pager; M = media viewer as `fullScreenCover`;
F = toolbar button `.focusable(false)`.

| Scenario | P | T | M |
|---|---|---|---|
| S1 cold launch | ✅ | ✅ | ✅ |
| S2 swipe → Following | ✅ | ✅ | ❌ |
| S3 swipe back | ✅ | (harness error) | ❌ |
| S4 swipe → menu | ✅ | ✅ | ✅ |
| S5 menu → toolbar → feed | ❌ | ✅ | ❌ |
| S6 hamburger → menu | ✅ | ✅ | ✅ |
| S9 post page | ✅ | (harness timeout) | ✅ |
| S10 post → Back | ✅ | ✅ | ❌ |
| S11 post → swipe back | ✅ | ✅ | ❌ |
| S12 photo viewer → close | blocked | blocked | ❌ |
| S16 sheet → Close | ✅ | ✅ | ❌ |
| S18 Bookmarks push | ✅ | ✅ | ✅ |
| S22 post → Back → hamburger | ❌ | ✅ | ✅ |

(S19 read STILL everywhere because the harness had scrolled the menu to its bottom first;
fixed in round 2 by trying the other direction. F and S were cancelled once T stood out.)

Reading: the three side-by-side live scroll views are the cause. P (one live page) fixes most
of it; the system pager fixes all of it, including the toolbar-button cases.

## Round 2

Matrix A / T / TM / TR with the harness fixes and S23 (Bookmarks popped by a swipe — the case
where a page-style TabView once showed a black screen). Results: _pending_.
