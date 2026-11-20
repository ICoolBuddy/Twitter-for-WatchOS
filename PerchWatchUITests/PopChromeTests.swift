import Foundation
import XCTest

/// Reproduces the device report (2026-11-20): after a pop the leading toolbar item
/// fades in a few points left of its final place and snaps there, and after a second
/// pop the menu button is gone.
///
/// This test does not assert a fix; it measures. It pushes a post and pops it three
/// times, printing the leading item's existence and frame at four moments each round:
/// on the feed (baseline), on the pushed screen, immediately after the pop gesture
/// (mid-transition), and after the settle. Every round also attaches a screenshot, so
/// the transition can be inspected visually.
///
///     POPCHROME <round> <phase> exists=<0|1> hittable=<0|1> x=… y=… w=… h=…
///
/// A missing `chrome.menuToggle` after a pop, or an `x` that drifts round after round,
/// is the bug; identical frames are the pass condition.
final class PopChromeTests: XCTestCase {
    private var app: XCUIApplication!

    /// Same fixture timeline as `CrownRoutingTests`: entry 0 is a photo post.
    private static let photoPost = "1860000000000000001"
    private static let settle: TimeInterval = 1.0

    override func setUpWithError() throws {
        continueAfterFailure = true        // measure all three rounds even if one fails
        app = XCUIApplication()
        app.launchArguments = ["-PerchFixtures", "YES", "-homeKind", "forYou"]
        app.launch()
        // The intro can take up to 3 s; wait for the first fixture post instead.
        XCTAssertTrue(element("post.open." + Self.photoPost).waitForExistence(timeout: 25),
                      "the fixture feed never appeared")
    }

    func testLeadingChromeAcrossRepeatedPops() throws {
        guard let baseline = measure("baseline") else {
            XCTFail("no leading item on the feed at launch")
            return
        }
        XCTAssertGreaterThan(baseline.width, 0, "the leading item has no size on the feed")

        for round in 1...3 {
            // Push the post.
            let post = element("post.open." + Self.photoPost)
            guard post.waitForExistence(timeout: 10) else {
                XCTFail("round \(round): the post link disappeared"); return
            }
            post.tap()
            guard element("probe.post").waitForExistence(timeout: 15) else {
                XCTFail("round \(round): the post page did not open"); return
            }
            Thread.sleep(forTimeInterval: Self.settle)
            _ = measure("\(round)-pushed", id: "chrome.back")

            // Pop it the way the owner does: a mid-screen swipe right (the same drag
            // CrownRoutingTests S11 uses; SwipeBack needs >22 pt from the edge).
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.62))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.62))
            start.press(forDuration: 0.08, thenDragTo: end)

            // Sample immediately: the pop animation is still running, which is the
            // moment the owner sees the icon left of its place. Each query takes tens
            // of milliseconds, so this catches 2–4 frames of the transition.
            for tick in 0..<4 {
                _ = measure("\(round)-mid\(tick)")
            }
            attach("round-\(round)-mid")

            Thread.sleep(forTimeInterval: Self.settle)
            guard let after = measure("\(round)-settled") else {
                XCTFail("round \(round): the menu button is missing after the pop")
                attach("round-\(round)-missing")
                continue
            }
            attach("round-\(round)-settled")

            // The pass condition: same place as on the first screen of this round.
            XCTAssertEqual(after.minX, baseline.minX, accuracy: 1.0,
                           "round \(round): leading item x drifted after the pop")
            XCTAssertEqual(after.minY, baseline.minY, accuracy: 1.0,
                           "round \(round): leading item y drifted after the pop")
        }
    }

    // MARK: Measurement

    /// The app's leading chrome: `chrome.menuToggle` on the pager, `chrome.back` on a
    /// pushed screen. Both use `.accessibilityAddTraits(.isButton)` but are gesture
    /// views, so the element type is not guaranteed — query any descendant.
    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    @discardableResult
    private func measure(_ phase: String, id: String = "chrome.menuToggle") -> CGRect? {
        let e = element(id)
        let exists = e.exists
        let hittable = exists && e.isHittable
        let frame = exists ? e.frame : .zero
        print(String(format: "POPCHROME %@ exists=%d hittable=%d x=%.1f y=%.1f w=%.1f h=%.1f",
                     phase, exists ? 1 : 0, hittable ? 1 : 0,
                     frame.minX, frame.minY, frame.width, frame.height))
        return exists ? frame : nil
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
