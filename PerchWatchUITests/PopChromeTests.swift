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
        XCTAssertTrue(waitFor("post.open." + Self.photoPost, timeout: 25),
                      "the fixture feed never appeared")
    }

    func testLeadingChromeAcrossRepeatedPops() throws {
        guard let baseline = measure("baseline") else {
            XCTFail("no leading item on the feed at launch")
            return
        }
        XCTAssertGreaterThan(baseline.width, 0, "the leading item has no size on the feed")

        for round in 1...3 {
            // Push the post. Both feed pages stay alive, so the identifier has copies;
            // tap the one on screen.
            guard tapOnScreen("post.open." + Self.photoPost) else {
                XCTFail("round \(round): the post link was not tappable"); return
            }
            guard waitFor("probe.post", timeout: 15) else {
                XCTFail("round \(round): the post page did not open"); return
            }
            Thread.sleep(forTimeInterval: Self.settle)
            // The pushed screen now uses watchOS' own chevron; report what the bar has.
            _ = measure("\(round)-pushed", id: "chrome.back")
            let barButtons = app.navigationBars.buttons.allElementsBoundByIndex
                .map { "\($0.label)|\($0.identifier)|\($0.exists)" }
            print("POPCHROME \(round)-navbar buttons=[\(barButtons.joined(separator: ", "))]")

            // Pop it the way the owner does: a mid-screen swipe right (the same drag
            // CrownRoutingTests S11 uses; SwipeBack needs >22 pt from the edge).
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.62))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.62))
            start.press(forDuration: 0.08, thenDragTo: end)

            // Screenshots first: the pop animation is still running, which is the
            // moment the owner sees the icon left of its place. Each capture takes
            // ~100 ms, so three of them span the transition.
            for tick in 0..<3 { attach("round-\(round)-mid\(tick)") }
            _ = measure("\(round)-mid-measure")

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

    /// All copies of an identifier. The pager keeps both feeds alive and a pushed
    /// screen leaves the feed's chrome in the tree underneath, so an identifier can
    /// match several elements (the single-match subscript throws in that case).
    private func copies(_ id: String) -> [XCUIElement] {
        app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex
    }

    private func waitFor(_ id: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if copies(id).contains(where: { $0.exists }) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Taps the first copy that is on screen and hittable.
    private func tapOnScreen(_ id: String) -> Bool {
        let screen = app.frame
        for e in copies(id) where e.exists && e.isHittable {
            let mid = CGPoint(x: e.frame.midX, y: e.frame.midY)
            guard screen.contains(mid) else { continue }
            e.tap()
            return true
        }
        return false
    }

    /// Measures the leading chrome: `chrome.menuToggle` on the pager, `chrome.back` on
    /// a pushed screen. Both carry `.accessibilityAddTraits(.isButton)` but are gesture
    /// views, so the element type is not guaranteed.
    ///
    /// Reports **every** copy (count + frames) because "the item is gone" and "the item
    /// is there but off screen / under the pushed screen" look the same to the owner.
    @discardableResult
    private func measure(_ phase: String, id: String = "chrome.menuToggle") -> CGRect? {
        let all = copies(id)
        let screen = app.frame
        var onScreen: [CGRect] = []
        var allFrames: [CGRect] = []
        for e in all where e.exists {
            let f = e.frame
            allFrames.append(f)
            let mid = CGPoint(x: f.midX, y: f.midY)
            if e.isHittable && screen.contains(mid) { onScreen.append(f) }
        }
        let picked = onScreen.first ?? allFrames.first
        let frames = allFrames.map { String(format: "%.0f,%.0f/%.0fx%.0f", $0.minX, $0.minY, $0.width, $0.height) }
        print("POPCHROME \(phase) id=\(id) copies=\(all.count) onScreen=\(onScreen.count) "
              + "picked=\(picked.map { String(format: "%.1f,%.1f %.1fx%.1f", $0.minX, $0.minY, $0.width, $0.height) } ?? "none") "
              + "frames=[\(frames.joined(separator: " | "))]")
        return picked
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
