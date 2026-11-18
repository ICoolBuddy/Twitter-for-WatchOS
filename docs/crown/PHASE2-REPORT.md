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

## Round 2 — run 44299883015 (2 cold launches each)

Harness fixes (probe existence, other crown direction at a list end, media posts first) plus
S23 = Bookmarks popped by a swipe — the case where a page-style TabView once showed a black
screen. R = rebuild the visible feed's scroll view (new identity) after a page change, pop,
sheet close or viewer close.

| Scenario | A (shipped) | TR |
|---|---|---|
| S1 cold launch | ✅ | ✅ |
| S2 / S3 swipes | ❌ | ✅ / ✅ |
| S4 / S6 to the menu | ✅ | ✅ |
| S5 menu → toolbar → feed | ❌ | ✅ |
| S10 / S11 post → back | ❌ | ✅ / ✅ |
| S12 photo viewer → close | ❌ 0/2 | ✅ (1 measured) |
| S16 sheet → Close | ❌ | ✅ |
| S18 Bookmarks push | ✅ | ✅ |
| S19 Bookmarks → Back → menu | ✅ | ✅ |
| S22 post → Back → hamburger | ✅ (1) | ✅ (1) |
| S23 Bookmarks → swipe pop → menu | ✅ | ✅ (menu on screen: no black screen) |

T and TM ran out of the 45-minute job budget before the media scenarios. The menu `List`
recovers after pops even on A; only the feed `ScrollView`s lose the crown.

R works but resets the feed to the top after every pop/swipe (new scroll view identity), so
plain T has to be measured on the media scenarios before choosing (round 3).

## Round 3 — deciding runs (GitHub Actions, 2 cold launches each)

| Scenario | T (system pager) — run 44311773405 | TM (system pager + viewer as `fullScreenCover`) — runs 44317472654 / 44321791777 / 44324654680 |
|---|---|---|
| S2 swipe → Following | ✅ 2/2 | ✅ 2/2 |
| S5 menu → toolbar → feed | ✅ 2/2 | — |
| S10 post → Back | ✅ 2/2 | ✅ 2/2 |
| S12 photo viewer → close | ❌ 0/2 | ✅ 2/2 |
| S14 video viewer → close | ❌ 0/2 | ✅ 2/2 |
| S21 GIF viewer → close | — | ✅ 2/2 |
| S23 Bookmarks → swipe pop | ✅ 2/2 | — |

Result: the system pager fixes swipes, toolbar buttons, pops and the sheet; closing the media
viewer additionally needs the viewer to be a real presentation (an overlay that disappears is
not a moment where watchOS re-picks the crown's scroll view). TM is the smallest change that
passes every measured scenario and keeps the feed's scroll position (TR passes too but resets
it). Trade-off: a `fullScreenCover` shows watchOS' own close (X) button and the clock in the
viewer (see the `media` screenshot), which the overlay viewer had hidden.

Still unmeasured (harness): Likes/Notifications pushed from the menu (row taps), media opened
inside the profile sheet.

## Shipped fix — verification on the branch (variant A = shipped code)

Run 44328430162 (commit a5ebc66: system pager + viewer as `fullScreenCover`): S1, S2, S4, S5,
S6, S10, S11, S12, S14, S18, S19, S22, S23 ✅; **S3 ❌ 0/2** (swiping back to a feed that was
already shown: a page swipe back does not make its scroll view appear again).

Run 44336548833 (commit 13e2467: a feed swiped back to gets a new scroll view identity and is
scrolled back to the post that was at the top): S2, **S3**, S4, S5, S6, S10, S11, S12 all ✅ 2/2.

Release build (Build workflow) green on both commits.
