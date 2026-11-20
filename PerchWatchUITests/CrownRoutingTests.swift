import Foundation
import XCTest

/// crown-lab (2026-11-18): does turning the Digital Crown — with NO touch after the
/// scenario's last navigation step — scroll the list that is on screen?
///
/// Every scenario runs three times from a cold launch and prints one
/// machine-readable line per attempt:
///
///     CROWN S7 1/3 STILL dy=0.0 y0=-0.0 y1=-0.0 h=120 v=248 note=…
///
/// The CI step ("Crown routing table" in `screens.yml`) greps those lines out of the
/// xcodebuild log and writes the k/3 table to `$GITHUB_STEP_SUMMARY`. Verdicts:
///
/// - `MOVED`   the probe's `y` moved by at least 20 pt without a touch: the crown
///             scrolls that list.
/// - `STILL`   the list is there and did not move: the crown is not routed to it.
/// - `BLOCKED` the scenario could not reach its screen (a navigation step failed).
///             Never counted as `STILL`, so a broken tap cannot look like a crown bug.
/// - `NOPROBE` the probe element did not exist: the measurement itself is broken.
/// - `SKIPPED` nothing to test (no GIF in the fixtures).
///
/// Launch arguments are the DEBUG fixture harness' (`-PerchFixtures YES`) plus a
/// pinned `homeKind`: swiping to Following writes it to UserDefaults, and every
/// scenario has to start on For You. `-homeKind forYou` makes the argument domain
/// win for reads (no app change; see `PerchSettings.homeKind`).
///
/// The probe itself is `PerchWatch/Debug/CrownProbe.swift`: `probe.<name>`, value
/// `y=<contentOffset.y> h=<content height> v=<viewport height>`. `h` vs `v` is what
/// separates "there was nothing to scroll" from "the crown did not reach it".
final class CrownRoutingTests: XCTestCase {

    // MARK: Constants

    /// Tweet ids in `PerchWatch/Debug/Fixtures/home_timeline.json`: entry 0 has one
    /// photo, entry 4 has one video (the only media in the fixture timeline).
    private enum FixtureID {
        static let photoPost = "1860000000000000001"
        static let videoPost = "1860000000000000042"
        /// Added for S21: a looping GIF right after the video.
        static let gifPost = "1860000000000000043"
    }

    /// Half-turns per measurement, four times: the brief's `delta: 0.5`, "a few
    /// times". Crown scrolling is non-inertial, so content moves only while rotating.
    private static let rotationDelta: CGFloat = 0.5
    private static let rotations = 4
    /// The pass mark: this many points of content travel means the crown reached it.
    private static let passMark = 20.0
    /// The one fixed wait, allowed by the brief: a settle after every navigation step
    /// (the pager's spring is 0.28 s, the media viewer's fade 0.18 s, sheet and pop
    /// animations are shorter) before the first crown rotation, so the measurement
    /// sees the finished layout. Everything else waits on a real signal.
    private static let settle: TimeInterval = 1.0
    /// `TEST_RUNNER_CROWN_ITERATIONS` (xcodebuild strips the prefix) lowers this for
    /// the variant matrix; the full baseline keeps three cold launches.
    private static let iterations: Int = {
        Int(ProcessInfo.processInfo.environment["CROWN_ITERATIONS"] ?? "") ?? 3
    }()
    /// The crown experiment the app runs (`-crownVariant`, see `CrownLab.swift`), from
    /// `TEST_RUNNER_CROWN_VARIANT`. "A" = the shipped code, unchanged.
    /// `TEST_RUNNER_CROWN_ONLY` = "S2,S5,S12": run only those scenarios (CI time budget).
    private static let only: Set<String>? = {
        let raw = ProcessInfo.processInfo.environment["CROWN_ONLY"] ?? ""
        let ids = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ids.isEmpty ? nil : Set(ids)
    }()

    private static func selected(_ id: String) -> Bool { only?.contains(id) ?? true }

    private static let variant: String = {
        let v = ProcessInfo.processInfo.environment["CROWN_VARIANT"] ?? ""
        return v.isEmpty ? "A" : v
    }()

    // MARK: State

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        // One failed iteration must not hide the rest: every attempt is data.
        continueAfterFailure = true
    }

    // MARK: Scenarios

    /// S1: cold launch, wait for the intro to finish (~3 s at the most), crown on
    /// `feed.forYou`.
    func test01_S1_coldLaunchForYou() {
        scenario("S1", probe: "feed.forYou") {
            guard self.onScreen("feed.forYou") else {
                return .blocked("For You is not the page on screen after the cold launch (\(self.pagerNote()))")
            }
            return .ready("cold launch, intro finished")
        }
    }

    /// S2: swipe left (For You -> Following), crown on `feed.following`.
    func test02_S2_swipeLeftToFollowing() {
        scenario("S2", probe: "feed.following") {
            guard self.onScreen("feed.forYou") else {
                return .blocked("not on For You before the swipe (\(self.pagerNote()))")
            }
            guard self.swipe(to: "feed.following", right: false) else {
                return .blocked("swipe left did not land on Following (\(self.pagerNote()))")
            }
            return .ready("swiped left to Following")
        }
    }

    /// S3: S2 then swipe right back, crown on `feed.forYou`.
    func test03_S3_swipeBackToForYou() {
        scenario("S3", probe: "feed.forYou") {
            guard self.swipe(to: "feed.following", right: false) else {
                return .blocked("swipe left did not land on Following (\(self.pagerNote()))")
            }
            guard self.swipe(to: "feed.forYou", right: true) else {
                return .blocked("swipe right from Following did not return to For You (\(self.pagerNote()))")
            }
            return .ready("Following, then swiped back right")
        }
    }

    /// S4: swipe right to the menu, crown on `menu`.
    func test04_S4_swipeRightToMenu() {
        scenario("S4", probe: "menu") {
            guard self.swipe(to: "menu", right: true) else {
                return .blocked("swipe right from For You did not open the menu (\(self.pagerNote()))")
            }
            return .ready("swiped right to the menu")
        }
    }

    /// S5: S4, then the toolbar button back to the feed, crown on `feed.forYou`.
    func test05_S5_menuToolbarBackToFeed() {
        scenario("S5", probe: "feed.forYou") {
            guard self.swipe(to: "menu", right: true) else {
                return .blocked("swipe right from For You did not open the menu (\(self.pagerNote()))")
            }
            guard self.tap("chrome.menuToggle") else {
                return .blocked("the leading toolbar button was not tappable on the menu")
            }
            self.settle()
            guard self.onScreen("feed.forYou") else {
                return .blocked("the toolbar button did not return to For You (\(self.pagerNote()))")
            }
            return .ready("menu, then the toolbar button back")
        }
    }

    /// S6: hamburger button -> menu, crown on `menu`.
    func test06_S6_hamburgerToMenu() {
        scenario("S6", probe: "menu") {
            guard self.tap("chrome.menuToggle") else {
                return .blocked("the hamburger button was not tappable on the feed")
            }
            self.settle()
            guard self.onScreen("menu") else {
                return .blocked("the hamburger button did not open the menu (\(self.pagerNote()))")
            }
            return .ready("hamburger button")
        }
    }

    /// S7: hamburger -> menu -> tap the Likes row (push), crown on `likes`.
    ///
    /// Note: the fixture Likes timeline is empty (`FixtureXClient.likes` returns no
    /// items), so this measures whether the crown reaches the pushed list at all, not
    /// that a long list scrolls. `S7b` repeats the same push on Notifications, which
    /// has rows, so the mechanism is measured with something that can move.
    func test07_S7_menuLikesPush() {
        scenario("S7", probe: "likes") {
            guard self.pushFromMenu("menu.likes", probe: "likes") else {
                return .blocked("could not push Likes from the menu")
            }
            return .ready("Likes pushed from the menu (fixture list is empty)")
        }
    }

    /// S7b (added): the same push on Notifications, whose fixture list has rows.
    func test08_S7b_menuNotificationsPush() {
        scenario("S7b", probe: "notifications") {
            guard self.pushFromMenu("menu.notifications", probe: "notifications") else {
                return .blocked("could not push Notifications from the menu")
            }
            return .ready("Notifications pushed from the menu")
        }
    }

    /// S8: S7, then the back button -> crown on `menu`.
    func test09_S8_likesBackToMenu() {
        scenario("S8", probe: "menu") {
            guard self.pushFromMenu("menu.likes", probe: "likes") else {
                return .blocked("could not push Likes from the menu")
            }
            let how = self.tapSystemBack()
            self.settle()
            guard !self.probe("likes").exists else {
                return .blocked("the Likes screen is still up (back tried via \(how))")
            }
            guard self.onScreen("menu") else {
                return .blocked("back from Likes landed on the wrong page (\(self.pagerNote()))")
            }
            return .ready("Likes, back via \(how)")
        }
    }

    /// S9: tap a post -> crown on `post`.
    func test10_S9_postDetail() {
        scenario("S9", probe: "post") {
            guard self.tap("post.open." + FixtureID.photoPost) else {
                return .blocked("the first post's text link was not tappable")
            }
            guard self.probe("post").waitForExistence(timeout: 10) else {
                return .blocked("the post page did not open")
            }
            return .ready("first post opened")
        }
    }

    /// S10: S9, then the back button -> `feed.forYou`.
    func test11_S10_postBackToFeedButton() {
        scenario("S10", probe: "feed.forYou") {
            guard self.tap("post.open." + FixtureID.photoPost) else {
                return .blocked("the first post's text link was not tappable")
            }
            guard self.probe("post").waitForExistence(timeout: 10) else {
                return .blocked("the post page did not open")
            }
            let how = self.tapSystemBack()
            self.settle()
            guard !self.probe("post").exists else {
                return .blocked("the post page is still up (back tried via \(how))")
            }
            guard self.onScreen("feed.forYou") else {
                return .blocked("back from the post landed on the wrong page (\(self.pagerNote()))")
            }
            return .ready("post, back via \(how)")
        }
    }

    /// S11: S9, then swipe right back -> `feed.forYou`. `SwipeBack` needs a start
    /// more than 22 pt from the left edge (closer is the system's own pop) and more
    /// than 55 pt of travel, so the drag starts mid-screen.
    func test12_S11_postBackToFeedSwipe() {
        scenario("S11", probe: "feed.forYou") {
            guard self.tap("post.open." + FixtureID.photoPost) else {
                return .blocked("the first post's text link was not tappable")
            }
            guard self.probe("post").waitForExistence(timeout: 10) else {
                return .blocked("the post page did not open")
            }
            let start = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.62))
            let end = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.62))
            start.press(forDuration: 0.08, thenDragTo: end)
            self.settle()
            guard !self.probe("post").exists else {
                return .blocked("swipe right did not pop the post")
            }
            guard self.onScreen("feed.forYou") else {
                return .blocked("swipe right popped to the wrong page (\(self.pagerNote()))")
            }
            return .ready("post, popped by a mid-screen swipe right")
        }
    }

    /// S12: tap a photo tile -> crown in the viewer (it zooms: recorded, not
    /// measured, it is a `digitalCrownRotation` page with no scroll probe) -> close
    /// button -> crown on `feed.forYou`.
    func test13_S12_photoViewer() {
        scenario("S12", probe: "feed.forYou") {
            guard self.openViewer(tile: "media.tile." + FixtureID.photoPost + ".0") else {
                return .blocked("the first post's photo tile did not open the viewer")
            }
            // Record only: no touch needed to rotate, then close.
            self.rotate()
            self.settle()
            let x = self.coverXNote()
            guard let how = self.closeViewer() else {
                return .blocked("the viewer would not close (swipe down / X), \(x)")
            }
            self.settle()
            guard !self.element("media.viewer").exists else {
                return .blocked("the viewer did not close")
            }
            return .ready("photo viewer opened, \(x), closed by \(how)")
        }
    }

    /// S13: the GIF half of S12. The fixture timeline has no GIF, so this is
    /// recorded as skipped rather than failed.
    func test14_S13_gifViewer() {
        guard Self.selected("S13") else { return }
        report("S13", 0, "SKIPPED", note: "measured as S21 (GIF fixture added)")
    }

    /// S14: S12 with the video in the fixture timeline (scrolled into reach first:
    /// a touch before the last navigation step is allowed).
    func test15_S14_videoViewer() {
        scenario("S14", probe: "feed.forYou", first: FixtureID.videoPost) {
            guard self.openViewer(tile: "media.tile." + FixtureID.videoPost + ".0") else {
                return .blocked("the video tile never became tappable")
            }
            self.rotate()
            self.settle()
            let x = self.coverXNote()
            guard let how = self.closeViewer() else {
                return .blocked("the viewer would not close (swipe down / X), \(x)")
            }
            self.settle()
            guard !self.element("media.viewer").exists else {
                return .blocked("the viewer did not close")
            }
            return .ready("video viewer opened, \(x), closed by \(how)")
        }
    }

    /// S15: tap an avatar -> profile sheet -> crown on `profile`.
    func test16_S15_profileSheet() {
        scenario("S15", probe: "profile") {
            guard self.tap("avatar." + FixtureID.photoPost) else {
                return .blocked("the first post's avatar was not tappable")
            }
            guard self.probe("profile").waitForExistence(timeout: 10) else {
                return .blocked("the profile sheet did not open")
            }
            return .ready("profile sheet from the first post's avatar")
        }
    }

    /// S16: S15, then the sheet's Close button -> crown on `feed.forYou`.
    func test17_S16_profileCloseBackToFeed() {
        scenario("S16", probe: "feed.forYou") {
            guard self.tap("avatar." + FixtureID.photoPost) else {
                return .blocked("the first post's avatar was not tappable")
            }
            guard self.probe("profile").waitForExistence(timeout: 10) else {
                return .blocked("the profile sheet did not open")
            }
            guard self.tap("sheet.close") else {
                return .blocked("the sheet's Close button was not tappable")
            }
            self.settle()
            guard !self.probe("profile").exists else {
                return .blocked("the sheet did not close")
            }
            guard self.onScreen("feed.forYou") else {
                return .blocked("closing the sheet left a different page (\(self.pagerNote()))")
            }
            return .ready("profile sheet, closed with Close")
        }
    }

    /// S17: crown-refresh at the top (rotate a lot, ten half-turns) then crown the
    /// other way, on `feed.forYou`. Whether the big rotation actually tripped the
    /// crown refresh (`PullToRefresh` needs 90 pt of accumulated overscroll) is
    /// recorded in the row, not asserted; the assertion is that the crown still
    /// scrolls afterwards.
    func test18_S17_crownRefreshAtTop() {
        let name = "feed.forYou"
        guard Self.selected("S17") else { return }
        for iteration in 1...Self.iterations {
            launch()
            guard probeExists(name), let start = read(name) else {
                report("S17", iteration, "NOPROBE", note: "probe.\(name) never appeared")
                XCTFail("S17: probe.\(name) never appeared")
                app.terminate()
                continue
            }
            guard onScreen(name) else {
                report("S17", iteration, "BLOCKED", note: "For You is not on screen (\(pagerNote()))")
                app.terminate()
                continue
            }
            settle()
            // A lot, at the top: the refresh path, whichever direction the crown
            // turns the list.
            rotate(times: 10)
            settle()
            let pill = ["Refreshing", "Updated", "Couldn't update"]
                .contains { app.staticTexts[$0].exists }
            let middle = read(name) ?? start
            rotate(clockwise: false)
            settle()
            let end = read(name)
            let dy = (end?.y ?? middle.y) - middle.y
            let verdict = abs(dy) >= Self.passMark ? "MOVED" : "STILL"
            report("S17", iteration, verdict, dy: dy, y0: middle.y, y1: end?.y,
                   reading: middle,
                   note: "up x10 then down x4, refresh pill \(pill ? "seen" : "not seen")")
            XCTAssertGreaterThanOrEqual(abs(dy), Self.passMark,
                                        "S17 iteration \(iteration): the crown did not scroll \(name) after rotating at the top")
            app.terminate()
        }
    }

    /// S18 (added): menu -> Bookmarks (push) -> crown on `bookmarks`.
    func test19_S18_menuBookmarksPush() {
        scenario("S18", probe: "bookmarks") {
            guard self.pushFromMenu("menu.bookmarks", probe: "bookmarks") else {
                return .blocked("could not push Bookmarks from the menu")
            }
            return .ready("Bookmarks pushed from the menu")
        }
    }

    /// S19 (added): Bookmarks, then back -> crown on `menu`.
    func test20_S19_bookmarksBackToMenu() {
        scenario("S19", probe: "menu") {
            guard self.pushFromMenu("menu.bookmarks", probe: "bookmarks") else {
                return .blocked("could not push Bookmarks from the menu")
            }
            let how = self.tapSystemBack()
            self.settle()
            guard !self.probe("bookmarks").exists else {
                return .blocked("the Bookmarks screen is still up (back tried via \(how))")
            }
            guard self.onScreen("menu") else {
                return .blocked("back from Bookmarks landed on the wrong page (\(self.pagerNote()))")
            }
            return .ready("Bookmarks, back via \(how)")
        }
    }

    /// S20 (added): Notifications (a list with rows), then back -> crown on `menu`.
    func test21_S20_notificationsBackToMenu() {
        scenario("S20", probe: "menu") {
            guard self.pushFromMenu("menu.notifications", probe: "notifications") else {
                return .blocked("could not push Notifications from the menu")
            }
            let how = self.tapSystemBack()
            self.settle()
            guard !self.probe("notifications").exists else {
                return .blocked("the Notifications screen is still up (back tried via \(how))")
            }
            guard self.onScreen("menu") else {
                return .blocked("back from Notifications landed on the wrong page (\(self.pagerNote()))")
            }
            return .ready("Notifications, back via \(how)")
        }
    }

    /// S21 (added): the GIF half of S12, now that the fixture timeline has one.
    func test22_S21_gifViewer() {
        scenario("S21", probe: "feed.forYou", first: FixtureID.gifPost) {
            guard self.openViewer(tile: "media.tile." + FixtureID.gifPost + ".0") else {
                return .blocked("the GIF tile never became tappable")
            }
            self.rotate()
            self.settle()
            let x = self.coverXNote()
            guard let how = self.closeViewer() else {
                return .blocked("the viewer would not close (swipe down / X), \(x)")
            }
            self.settle()
            guard !self.element("media.viewer").exists else {
                return .blocked("the viewer did not close")
            }
            return .ready("GIF viewer opened, \(x), closed by \(how)")
        }
    }

    /// S22 (added): post page, then back with the button, then the hamburger -> crown on
    /// `menu` (a tapped control after a pop).
    func test23_S22_postBackThenHamburger() {
        scenario("S22", probe: "menu") {
            guard self.tap("post.open." + FixtureID.photoPost) else {
                return .blocked("the first post's text link was not tappable")
            }
            guard self.probe("post").waitForExistence(timeout: 10) else {
                return .blocked("the post page did not open")
            }
            let how = self.tapSystemBack()
            self.settle()
            guard !self.probe("post").exists else {
                return .blocked("the post page is still up (back tried via \(how))")
            }
            guard self.tap("chrome.menuToggle") else {
                return .blocked("the hamburger button was not tappable after the pop")
            }
            self.settle()
            guard self.onScreen("menu") else {
                return .blocked("the hamburger did not open the menu (\(self.pagerNote()))")
            }
            return .ready("post, back via \(how), hamburger")
        }
    }

    /// S24 (device bug 2026-11-18): open a post, open its photo, close the viewer
    /// (swipe down), then ONE back tap must pop the post -> crown on `feed.forYou`.
    /// On the device the first back tap after the viewer did nothing.
    func test25_S24_postMediaThenBack() { postMediaThenBack("S24", preferX: false) }

    /// S24b: S24, closing the viewer with watchOS' X when it has one.
    func test26_S24b_postMediaXThenBack() { postMediaThenBack("S24b", preferX: true) }

    private func postMediaThenBack(_ id: String, preferX: Bool) {
        scenario(id, probe: "feed.forYou") {
            guard self.tap("post.open." + FixtureID.photoPost) else {
                return .blocked("the first post's text link was not tappable")
            }
            guard self.probe("post").waitForExistence(timeout: 10) else {
                return .blocked("the post page did not open")
            }
            self.settle()
            guard self.tapHittable("media.tile." + FixtureID.photoPost + ".0"),
                  self.element("media.viewer").waitForExistence(timeout: 10) else {
                return .blocked("the post page's photo did not open the viewer")
            }
            self.settle()
            let x = self.coverXNote()
            guard let how = self.closeViewer(preferX: preferX) else {
                return .blocked("the viewer would not close (\(x))")
            }
            self.settle()
            guard self.probe("post").exists else {
                return .blocked("closing the viewer left the post page")
            }
            let first = self.tapSystemBack()
            self.settle()
            if self.probe("post").exists {
                let second = self.tapSystemBack()
                self.settle()
                let popped = !self.probe("post").exists
                return .blocked("BUG first back tap ignored (\(first)); second tap \(popped ? "popped" : "also ignored") (\(second)); \(x), closed by \(how)")
            }
            guard self.onScreen("feed.forYou") else {
                return .blocked("back landed on the wrong page (\(self.pagerNote()))")
            }
            return .ready("post, photo, \(x), closed by \(how), one back tap (\(first))")
        }
    }

    /// SP1 (device bug 2026-11-18): read For You a few posts down, swipe to Following
    /// and back -> For You is where it was (not the top), and the crown scrolls it.
    func test27_SP1_placeKeptForYou() {
        placeKept("SP1", feed: "feed.forYou",
                  away: { self.swipe(to: "feed.following", right: false) },
                  back: { self.swipe(to: "feed.forYou", right: true) })
    }

    /// SP2: the same for Following (swipe to For You and back).
    func test28_SP2_placeKeptFollowing() {
        placeKept("SP2", feed: "feed.following",
                  away: { self.swipe(to: "feed.forYou", right: true) },
                  back: { self.swipe(to: "feed.following", right: false) })
    }

    /// SP3: For You a few posts down, hamburger to the menu, toolbar back to the feed.
    func test29_SP3_placeKeptViaMenu() {
        placeKept("SP3", feed: "feed.forYou",
                  away: {
                      guard self.tap("chrome.menuToggle", attempts: 1) else { return false }
                      self.settle()
                      return self.onScreen("menu")
                  },
                  back: {
                      guard self.tap("chrome.menuToggle", attempts: 1) else { return false }
                      self.settle()
                      return self.onScreen("feed.forYou")
                  })
    }

    private func placeKept(_ id: String, feed: String,
                           away: @escaping () -> Bool, back: @escaping () -> Bool) {
        scenario(id, probe: feed) {
            if feed == "feed.following" {
                guard self.swipe(to: "feed.following", right: false) else {
                    return .blocked("swipe left did not land on Following (\(self.pagerNote()))")
                }
            }
            for _ in 0..<3 {
                self.app.swipeUp()
                Thread.sleep(forTimeInterval: 0.4)
            }
            self.settle()
            guard let before = self.read(feed), abs(before.y) > 150 else {
                return .blocked("could not scroll \(feed) down first")
            }
            guard away() else { return .blocked("could not leave \(feed) (\(self.pagerNote()))") }
            guard back() else { return .blocked("could not return to \(feed) (\(self.pagerNote()))") }
            self.settle()
            guard let after = self.read(feed) else {
                return .blocked("probe.\(feed) unreadable after returning")
            }
            // The scroll view is never recreated now: watchOS keeps the offset, so the
            // same post is on top at the same pixel. No restore, no black cover.
            let drift = after.y - before.y
            let key = feed == "feed.forYou" ? "place.forYou" : "place.following"
            let evidence = (self.element(key).value as? String) ?? "no place marker"
            let place = String(format: "y %.0f -> %.0f (drift %.0f)", before.y, after.y, drift)
            guard abs(drift) <= 5 else { return .blocked("BUG place moved: \(place) [\(evidence)]") }
            return .ready("place kept: \(place)")
        }
    }

    /// SR1: crown turned *up* at the top of For You (past the top: the rubber band)
    /// -> a refresh starts once the crown stops (release-to-refresh), and the crown
    /// still scrolls the feed afterwards.
    func test30_SR1_crownRefreshAtTop() { refreshAtTop("SR1", finger: false) }

    /// SR2: finger pull down from the top past the threshold, then let go -> refresh.
    func test31_SR2_fingerPullRelease() { refreshAtTop("SR2", finger: true) }

    private func refreshAtTop(_ id: String, finger: Bool) {
        scenario(id, probe: "feed.forYou") {
            guard self.onScreen("feed.forYou") else {
                return .blocked("For You is not on screen (\(self.pagerNote()))")
            }
            var crownNote = ""
            // The status line says the refresh ran ("Refreshing", then "Updated" for
            // 1.5 s). It is polled *between* crown turns too: the refresh can fire
            // mid-rotation, long before the rotation finishes.
            let pill = ["Refreshing", "Updated", "Couldn't update"]
            var seen = false
            func poll() {
                if !seen { seen = pill.contains { self.app.staticTexts[$0].exists } }
            }
            if finger {
                let start = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                let end = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
                // The plain variant (the velocity/hold overload may not exist on watchOS).
                start.press(forDuration: 0.1, thenDragTo: end)
            } else {
                // Which crown direction scrolls up is not ours to assume: the one that
                // leaves the probe at (or above) the top is the refresh direction.
                let before = self.read("feed.forYou")?.y ?? 0
                self.rotate(clockwise: false, times: 10)
                // Poll before the (slow) probe read: "Updated" is only up for 1.5 s.
                poll()
                let after = self.read("feed.forYou")?.y ?? 0
                if after > before + 20 {
                    // That scrolled down: go back to the top and turn the other way.
                    self.rotate(clockwise: true, times: 20)
                }
                poll()
                // `os` = the overscroll travel the crown actually produced. 0 means the
                // crown never rubber-bands at the top, so no threshold can fire.
                if let r = self.read("feed.forYou") {
                    crownNote = String(format: " (crown os=%.1f mx=%.1f mn=%.1f fresh=%.1f dip=%.0f) [%@]",
                                       r.os, r.mx, r.mn, r.fr, r.dip, String(r.raw.prefix(220)))
                }
            }
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline, !seen {
                poll()
                if !seen { Thread.sleep(forTimeInterval: 0.2) }
            }
            guard seen else { return .blocked("BUG no refresh after \(finger ? "the pull + release" : "the crown at the top")\(crownNote)") }
            return .ready("refresh ran after \(finger ? "pull + release" : "crown at the top")\(crownNote)")
        }
    }

    /// S23 (added): Bookmarks pushed from the menu, popped by a mid-screen swipe right ->
    /// crown on `menu`. A page-style TabView once left a black screen exactly here; the
    /// menu probe being on screen is the check that the pager is still drawn.
    func test24_S23_bookmarksSwipeBackToMenu() {
        scenario("S23", probe: "menu") {
            guard self.pushFromMenu("menu.bookmarks", probe: "bookmarks") else {
                return .blocked("could not push Bookmarks from the menu")
            }
            let start = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.62))
            let end = self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.62))
            start.press(forDuration: 0.08, thenDragTo: end)
            self.settle()
            guard !self.probe("bookmarks").exists else {
                return .blocked("swipe right did not pop Bookmarks")
            }
            guard self.onScreen("menu") else {
                return .blocked("after the swipe pop the menu is not on screen — black screen? (\(self.pagerNote()))")
            }
            return .ready("Bookmarks, popped by a mid-screen swipe right")
        }
    }

    /// SHOT (diagnostic, 2026-11-20): screenshots while switching timelines, to see
    /// what "a rectangle box appears when going from For You to Following" is.
    func test40_switchShots() {
        guard Self.selected("SHOT") else { return }
        launch()
        shot("0-launch")
        guard swipe(to: "feed.following", right: false) else {
            XCTFail("SHOT: could not reach Following"); return
        }
        app.swipeUp(); Thread.sleep(forTimeInterval: 0.4)
        app.swipeUp(); Thread.sleep(forTimeInterval: 0.6)
        shot("1-following-scrolled")
        guard swipe(to: "feed.forYou", right: true) else {
            XCTFail("SHOT: could not return to For You"); return
        }
        Thread.sleep(forTimeInterval: 0.6)
        shot("2-forYou")
        // Return to Following with raw swipes so the first moments are captured.
        app.swipeLeft()
        shot("3-return-immediate")
        Thread.sleep(forTimeInterval: 0.3)
        shot("4-return-300ms")
        Thread.sleep(forTimeInterval: 0.7)
        shot("5-return-1s")
        Thread.sleep(forTimeInterval: 1.0)
        shot("6-return-2s")
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// S25 (device report 2026-11-20): the system back chevron was ignored while the
    /// list was still decelerating. Tap it right after a swipe, with no settle.
    func test41_S25_backWhileDecelerating() {
        scenario("S25", probe: "feed.forYou") {
            guard self.tap("post.open." + FixtureID.photoPost) else {
                return .blocked("the first post's text link was not tappable")
            }
            guard self.probe("post").waitForExistence(timeout: 10) else {
                return .blocked("the post page did not open")
            }
            self.settle()
            self.app.swipeUp()                       // still decelerating below
            // A plain coordinate tap in the back corner: no accessibility query, which
            // itself timed out while the main thread was busy (the symptom under test).
            self.app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.11)).tap()
            Thread.sleep(forTimeInterval: 1.2)
            let how = "coordinate (0.10, 0.11)"
            guard !self.probe("post").exists else {
                return .blocked("BUG back ignored while decelerating (tapped via \(how))")
            }
            guard self.onScreen("feed.forYou") else {
                return .blocked("back popped to the wrong page (\(self.pagerNote()))")
            }
            return .ready("back while decelerating, one tap (\(how))")
        }
    }

    /// S26: the root toolbar button (back to the feed) right after scrolling the menu.
    func test42_S26_menuBackWhileDecelerating() {
        scenario("S26", probe: "feed.forYou") {
            guard self.tap("chrome.menuToggle") else { return .blocked("hamburger not tappable") }
            self.settle()
            guard self.onScreen("menu") else { return .blocked("menu did not open") }
            self.app.swipeUp()                       // menu list decelerating
            guard self.tap("chrome.menuToggle", attempts: 1) else {
                return .blocked("toolbar button not tappable on the menu")
            }
            Thread.sleep(forTimeInterval: 1.2)
            guard self.onScreen("feed.forYou") else {
                return .blocked("BUG toolbar back ignored while the menu was scrolling (\(self.pagerNote()))")
            }
            return .ready("menu toolbar back while decelerating")
        }
    }

    // MARK: The runner

    private enum StepResult {
        /// On the target screen; the associated string goes in the row's note.
        case ready(String)
        /// The scenario could not get where it needs to be; the string says why.
        case blocked(String)
    }

    /// Three cold launches of one scenario. Each attempt: launch, run the steps,
    /// settle once, read the probe, turn the crown with no touch in between, settle,
    /// read again, report and assert.
    private func scenario(_ id: String, probe name: String, first: String? = nil,
                          steps: @escaping () -> StepResult) {
        guard Self.selected(id) else { return }
        for iteration in 1...Self.iterations {
            launch(first: first)
            switch steps() {
            case .blocked(let why):
                report(id, iteration, "BLOCKED", note: why)
            case .ready(let note):
                settle()
                guard let before = read(name) else {
                    report(id, iteration, "NOPROBE", note: "probe.\(name) is missing or unreadable")
                    XCTFail("\(id) iteration \(iteration): probe.\(name) is missing or unreadable")
                    app.terminate()
                    continue
                }
                rotate()
                settle()
                var after = read(name)
                // A list already at its end cannot move further down: turn the other
                // way (still no touch) before calling it STILL.
                if let a = after, abs(a.y - before.y) < Self.passMark {
                    rotate(clockwise: false)
                    settle()
                    after = read(name)
                }
                guard let after else {
                    report(id, iteration, "NOPROBE", reading: before,
                           note: "probe.\(name) became unreadable after the crown")
                    XCTFail("\(id) iteration \(iteration): probe.\(name) became unreadable after the crown")
                    app.terminate()
                    continue
                }
                let dy = after.y - before.y
                let verdict = abs(dy) >= Self.passMark ? "MOVED" : "STILL"
                report(id, iteration, verdict, dy: dy, y0: before.y, y1: after.y,
                       reading: before, note: note)
                XCTAssertGreaterThanOrEqual(abs(dy), Self.passMark,
                                            "\(id) iteration \(iteration): the crown did not scroll probe.\(name) (\(note))")
            }
            app.terminate()
        }
    }

    // MARK: Launch

    private func launch(first: String? = nil) {
        let app = XCUIApplication()
        app.launchArguments = ["-PerchFixtures", "YES", "-homeKind", "forYou",
                               "-crownVariant", Self.variant]
        if let first { app.launchArguments += ["-PerchFixtureFirst", first] }
        let launchedAt = Date()
        app.launch()
        self.app = app
        waitForIntro(launchedAt, first: first)
    }

    /// `LaunchIntroView` ends as soon as the feed has content and at 3 s at the very
    /// latest. The "Perch" label is an accessibility element in every case; the
    /// worst-case cover below is the belt for the case where SwiftUI does not expose
    /// the overlay at all (then nothing could be waited for). Last, wait for the
    /// first fixture post: the probe alone would happily measure a skeleton list.
    private func waitForIntro(_ launchedAt: Date, first: String? = nil) {
        let deadline = Date().addingTimeInterval(15)
        while introVisible() && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
        let elapsed = Date().timeIntervalSince(launchedAt)
        let cover: TimeInterval = 3.6      // the intro's own maximum is 3 s
        if elapsed < cover { Thread.sleep(forTimeInterval: cover - elapsed) }
        _ = element("post.open." + (first ?? FixtureID.photoPost)).waitForExistence(timeout: 20)
    }

    private func introVisible() -> Bool {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Perch"))
            .count > 0
    }

    // MARK: Elements

    /// Type-agnostic lookup: a probe is a `Text`, a row can be a button or a link,
    /// and XCUITest's element type for SwiftUI containers is not contract.
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }

    private func elementExists(_ identifier: String, timeout: TimeInterval = 10) -> Bool {
        element(identifier).waitForExistence(timeout: timeout)
    }

    /// Both feed pages render the same fixture posts and both stay alive in the pager,
    /// so their identifiers repeat (a LazyVStack also only realizes what is near the
    /// screen). Prefer the copy on the page that is on screen: the three pages sit side
    /// by side, so mid-x decides.
    private func onScreenCopy(_ identifier: String) -> XCUIElement? {
        let screen = app.frame
        var fallback: XCUIElement?
        for candidate in app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex {
            guard candidate.exists else { continue }
            if fallback == nil { fallback = candidate }
            let midX = candidate.frame.midX
            if midX >= screen.minX && midX < screen.maxX { return candidate }
        }
        return fallback
    }

    private func probe(_ name: String) -> XCUIElement {
        element("probe." + name)
    }

    private func probeExists(_ name: String) -> Bool {
        probe(name).waitForExistence(timeout: 20)
    }

    /// The pager slides its three pages sideways in one HStack: the page on screen is
    /// the only one whose probe sits inside the display. Existence proves nothing
    /// (all three pages are alive), so every scenario checks this before measuring.
    private func onScreen(_ name: String) -> Bool {
        // The system pager drops off-screen pages from the tree: reading the frame of
        // an element that does not exist fails the test instead of returning false.
        guard probe(name).exists else { return false }
        let frame = probe(name).frame
        let screen = app.frame
        guard frame.width > 0, screen.width > 0 else { return false }
        return frame.midX >= screen.minX && frame.midX < screen.maxX
            && frame.midY >= screen.minY && frame.midY < screen.maxY
    }

    /// Where the three pages are, for the notes column.
    private func pagerNote() -> String {
        ["menu", "feed.forYou", "feed.following"]
            .map { probe($0).exists ? "\($0)@\(Int(probe($0).frame.minX))" : "\($0)@gone" }
            .joined(separator: " ")
    }

    /// Taps a control, scrolling the list below it into reach first when it is off
    /// screen or not realized yet (a touch *before* the scenario's last navigation
    /// step is fine).
    @discardableResult
    private func tap(_ identifier: String, attempts: Int = 8) -> Bool {
        for _ in 0..<attempts {
            if let target = onScreenCopy(identifier), target.isHittable {
                target.tap()
                return true
            }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        if let target = onScreenCopy(identifier), target.isHittable {
            target.tap()
            return true
        }
        return false
    }

    // MARK: Navigation

    private func settle() {
        Thread.sleep(forTimeInterval: Self.settle)
    }

    /// One page swipe plus the settle, then proof from the probes.
    private func swipe(to page: String, right: Bool) -> Bool {
        for _ in 0..<2 {
            if right { app.swipeRight() } else { app.swipeLeft() }
            settle()
            if onScreen(page) { return true }
        }
        return false
    }

    /// Menu -> a pushed list. Leaves the pushed screen on top.
    ///
    /// The menu's `List` rows did not expose their identifiers to XCUITest (baseline
    /// run: every push BLOCKED), so fall back to the row's visible label.
    private func pushFromMenu(_ row: String, probe name: String) -> Bool {
        guard tap("chrome.menuToggle") else { return false }
        settle()
        guard onScreen("menu") else { return false }
        let label = Self.menuLabels[row] ?? row
        guard tapLabel(label, attempts: 1) || tap(row, attempts: 1) || tapLabel(label) else {
            print("CROWNDEBUG menu row \(row) / '\(label)' not found; buttons: " +
                  app.buttons.allElementsBoundByIndex.prefix(30)
                    .map { "\($0.identifier)|\($0.label)" }.joined(separator: ", "))
            return false
        }
        return probe(name).waitForExistence(timeout: 10)
    }

    private static let menuLabels = [
        "menu.likes": "Likes",
        "menu.notifications": "Notifications",
        "menu.bookmarks": "Bookmarks",
    ]

    /// Taps the first on-screen, hittable element whose label is (or starts with) `label`.
    private func tapLabel(_ label: String, attempts: Int = 6) -> Bool {
        let predicate = NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")
        // First as the list is, then towards the top (the identifier lookup before this
        // may have scrolled the menu down past the row), then towards the bottom.
        for attempt in 0..<attempts {
            if attempt > 0 {
                if attempt <= 2 { app.swipeDown() } else { app.swipeUp() }
                Thread.sleep(forTimeInterval: 0.4)
            }
            let screen = app.frame
            for candidate in app.descendants(matching: .any).matching(predicate).allElementsBoundByIndex
            where candidate.exists && candidate.isHittable {
                let mid = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
                guard screen.contains(mid) else { continue }
                candidate.tap()
                return true
            }
        }
        return false
    }

    /// The pushed screen's back control is watchOS' own chevron, so its identifier is
    /// not ours to set. Try the label, then any navigation-bar button in the left half
    /// (the post page's Save button is on the right), then the corner where watchOS
    /// draws it. The caller always verifies that the screen actually popped.
    private func tapSystemBack() -> String {
        let named = app.navigationBars.buttons["Back"]
        if named.exists && named.isHittable {
            named.tap()
            return "navigation bar 'Back'"
        }
        let loose = app.buttons["Back"]
        if loose.exists && loose.isHittable {
            loose.tap()
            return "button 'Back'"
        }
        let bar = app.navigationBars.firstMatch
        if bar.exists {
            let leftHalf = app.frame.minX + app.frame.width * 0.4
            for button in bar.buttons.allElementsBoundByIndex
            where button.exists && button.frame.midX < leftHalf {
                button.tap()
                return "navigation bar button '\(button.label)'"
            }
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.12)).tap()
        return "coordinate (0.10, 0.12)"
    }

    // MARK: Media viewer

    private func openViewer(tile: String) -> Bool {
        let direct = element(tile)
        if direct.waitForExistence(timeout: 5), direct.frame.width > 0 {
            direct.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else {
            guard tap(tile) else { return false }
        }
        return element("media.viewer").waitForExistence(timeout: 10)
    }

    /// Closes the viewer and says how: `swipe` (drag down, the viewer's own way out)
    /// or `X` (watchOS' cover button, only when `preferX` or the swipe did nothing).
    /// `nil` = it would not close.
    private func closeViewer(preferX: Bool = false) -> String? {
        let viewer = element("media.viewer")
        for attempt in 0..<4 {
            guard viewer.exists else { return attempt == 0 ? "already closed" : "swipe" }
            if preferX || attempt >= 2, let system = systemCoverClose() {
                system.tap()
                Thread.sleep(forTimeInterval: 0.8)
                if !viewer.exists { return "X" }
                continue
            }
            swipeDownViewer()
            Thread.sleep(forTimeInterval: 0.8)
            if !viewer.exists { return "swipe" }
        }
        return viewer.exists ? nil : "swipe"
    }

    /// A downward drag over the middle of the media (more than the viewer's 60 pt).
    private func swipeDownViewer() {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// "X visible" / "X hidden": whether watchOS draws its close button on the cover.
    private func coverXNote() -> String {
        systemCoverClose() == nil ? "X hidden" : "X visible"
    }

    /// Taps the first on-screen, hittable copy of `identifier` (a pushed screen can
    /// leave the feed's copy of the same post in the tree underneath).
    private func tapHittable(_ identifier: String, attempts: Int = 6) -> Bool {
        for _ in 0..<attempts {
            let screen = app.frame
            for candidate in app.descendants(matching: .any).matching(identifier: identifier).allElementsBoundByIndex
            where candidate.exists && candidate.isHittable {
                let mid = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
                guard screen.contains(mid) else { continue }
                candidate.tap()
                return true
            }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    /// The close (X) button watchOS draws on a `fullScreenCover`, if any.
    private func systemCoverClose() -> XCUIElement? {
        for label in ["Close", "Dismiss", "Cancel"] {
            for b in app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
            where b.exists && b.isHittable {
                return b
            }
        }
        return nil
    }

    // MARK: Crown

    /// Turns the crown with no touch in between: watchOS hands the crown to a scroll
    /// view on a finger touch, so the last thing before this must be navigation.
    private func rotate(clockwise: Bool = true, times: Int = CrownRoutingTests.rotations,
                        delta: CGFloat = CrownRoutingTests.rotationDelta) {
        for _ in 0..<times {
            XCUIDevice.shared.rotateDigitalCrown(delta: clockwise ? delta : -delta)
        }
    }

    // MARK: Reading and reporting

    /// `y=-3.0 h=980 v=248 os=12.0 mx=4.0` from the probe.
    private struct Reading {
        var y = 0.0
        var h = 0.0
        var v = 0.0
        /// Positive overscroll travel accumulated since launch (crown refresh input).
        var os = 0.0
        var mx = 0.0
        /// The deepest the band went below the top (a bounce, or a real scroll down).
        var mn = 0.0
        /// The part of `os` that started from the top, and how often it unwound.
        var fr = 0.0
        var dip = 0.0
        /// The whole value, including the app's own trace (`t=`).
        var raw = ""

        init?(_ raw: String) {
            self.raw = raw
            var sawY = false
            for field in raw.split(separator: " ") {
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let value = Double(parts[1]) else { continue }
                switch parts[0] {
                case "y": y = value; sawY = true
                case "h": h = value
                case "v": v = value
                case "os": os = value
                case "mx": mx = value
                case "mn": mn = value
                case "fr": fr = value
                case "dip": dip = value
                default: break
                }
            }
            guard sawY else { return nil }
        }
    }

    private func read(_ name: String) -> Reading? {
        let target = probe(name)
        guard target.exists, let raw = target.value as? String else { return nil }
        return Reading(raw)
    }

    /// One machine-readable line per attempt; the CI step greps these to build the
    /// k/3 table. Keep the shape: `CROWN <id> <i>/<n> <VERDICT> dy=… y0=… y1=… h=… v=… note=…`.
    private func report(_ id: String, _ iteration: Int, _ verdict: String,
                        dy: Double? = nil, y0: Double? = nil, y1: Double? = nil,
                        reading: Reading? = nil, note: String) {
        var line = "CROWN \(id) \(iteration)/\(Self.iterations) \(verdict)"
        if let dy { line += String(format: " dy=%.1f", dy) }
        if let y0 { line += String(format: " y0=%.1f", y0) }
        if let y1 { line += String(format: " y1=%.1f", y1) }
        if let reading { line += String(format: " h=%.0f v=%.0f", reading.h, reading.v) }
        line += " var=" + Self.variant
        line += " note=" + note
        print(line)
    }
}
