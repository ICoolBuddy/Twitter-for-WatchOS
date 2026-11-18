import XCTest
@testable import XKit

/// The cases from the nav review's bug-5 table (46 mm, width 208).
final class PagerSwipeTests: XCTestCase {
    let w = 208.0

    func testDeliberateDragPages() {
        XCTAssertEqual(PagerSwipe.target(page: 1, width: w, dx: 80, dy: 29, predicted: 80), 0)
        XCTAssertEqual(PagerSwipe.target(page: 1, width: w, dx: -80, dy: 10, predicted: -90), 2)
    }

    func testFastShortFlickPages() {
        XCTAssertEqual(PagerSwipe.target(page: 1, width: w, dx: 50, dy: 7, predicted: 150), 0)
    }

    func testArcingScrollDoesNotPage() {
        // Released after a 150 pt scroll with a 40 pt arc: both checks fail.
        XCTAssertEqual(PagerSwipe.target(page: 1, width: w, dx: 40, dy: 150, predicted: 120), 1)
    }

    func testShortSlowDragDoesNotPage() {
        XCTAssertEqual(PagerSwipe.target(page: 1, width: w, dx: 60, dy: 5, predicted: 60), 1)
    }

    func testPulledBackThrowDoesNotPage() {
        XCTAssertEqual(PagerSwipe.target(page: 1, width: w, dx: 90, dy: 5, predicted: -20), 1)
    }

    func testEdgesClamp() {
        XCTAssertEqual(PagerSwipe.target(page: 0, width: w, dx: 120, dy: 0, predicted: 140), 0)
        XCTAssertEqual(PagerSwipe.target(page: 2, width: w, dx: -120, dy: 0, predicted: -140), 2)
    }

    func testAxis() {
        XCTAssertNil(PagerSwipe.axis(decided: nil, dx: 10, dy: 10))                       // still deciding
        XCTAssertEqual(PagerSwipe.axis(decided: nil, dx: 25, dy: 5), .horizontal)
        XCTAssertEqual(PagerSwipe.axis(decided: nil, dx: 5, dy: 25), .vertical)
        XCTAssertEqual(PagerSwipe.axis(decided: nil, dx: 24, dy: 24), nil)                // diagonal, in window
        XCTAssertEqual(PagerSwipe.axis(decided: nil, dx: 32, dy: 30), .vertical)          // diagonal past window
        XCTAssertEqual(PagerSwipe.axis(decided: .vertical, dx: 120, dy: 10), .vertical)   // stays vertical
        // The revoke: an early horizontal pivot that turns into a scroll.
        XCTAssertEqual(PagerSwipe.axis(decided: .horizontal, dx: 20, dy: 60), .vertical)
        XCTAssertEqual(PagerSwipe.axis(decided: .horizontal, dx: 80, dy: 30), .horizontal)
    }
}
