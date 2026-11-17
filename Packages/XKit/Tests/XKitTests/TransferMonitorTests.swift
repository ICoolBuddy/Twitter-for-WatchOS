import XCTest
@testable import XKit

final class TransferMonitorTests: XCTestCase {
    func testFormatRate() {
        XCTAssertEqual(TransferMonitor.formatRate(0), "0 KB/s")
        XCTAssertEqual(TransferMonitor.formatRate(12_000), "12 KB/s")
        XCTAssertEqual(TransferMonitor.formatRate(1_200_000), "1.2 MB/s")
        XCTAssertEqual(TransferMonitor.formatRate(850), "850 B/s")
    }

    func testActiveRequestsAndBytes() {
        let monitor = TransferMonitor()
        var snap = monitor.snapshot()
        XCTAssertEqual(snap.activeRequests, 0)
        XCTAssertEqual(snap.bytesReceived, 0)
        XCTAssertEqual(snap.bytesPerSecond, 0)

        let a = monitor.begin()
        let b = monitor.begin()
        XCTAssertEqual(monitor.snapshot().activeRequests, 2)

        monitor.add(16_384, to: a)
        monitor.add(16_384, to: a)
        snap = monitor.snapshot()
        XCTAssertEqual(snap.bytesReceived, 32_768)
        XCTAssertGreaterThan(snap.bytesPerSecond, 0)

        monitor.end(a)
        monitor.end(b)
        XCTAssertEqual(monitor.snapshot().activeRequests, 0)
    }

    func testSharedIsUsableFromAnyThread() {
        let monitor = TransferMonitor.shared
        let before = monitor.snapshot().bytesReceived
        let id = monitor.begin()
        monitor.add(1_024, to: id)
        monitor.end(id)
        XCTAssertEqual(monitor.snapshot().bytesReceived, before + 1_024)
    }
}
