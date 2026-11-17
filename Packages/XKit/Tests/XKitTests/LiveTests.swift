import XCTest
@testable import XKit

/// Hits public, logged-out x.com pages. Skipped unless PERCH_LIVE=1.
final class LiveTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["PERCH_LIVE"] == "1" else { throw XCTSkip("set PERCH_LIVE=1") }
    }

    func testEndpointDiscovery() async throws {
        let cfg = try await EndpointDiscovery().discover(base: EndpointConfig.bundled)
        for op in Operation.allCases { XCTAssertNotNil(cfg.info(op), op.rawValue) }
        print("LIVE discovered HomeTimeline:", cfg.info(.homeTimeline)?.queryId ?? "-", "legacy signer:", cfg.legacySigner?.indices ?? [])
    }

    func testXWebSignerScan() async throws {
        let f = TransactionMaterialFetcher(credentials: nil, config: .bundled)
        let html = try await Fetcher(transport: URLSessionTransport(), cookieHeader: nil).text(URL(string: "https://x.com/")!)
        let scripts = Regex.matches(#"https://[\w.-]+/x-web/[\w./-]+\.js"#, in: html).map { $0[0] }
        XCTAssertFalse(scripts.isEmpty)
        let ind = try await f.scanXWeb(scripts: scripts)
        print("LIVE x-web signer indices:", ind ?? [])
        XCTAssertEqual(ind?.count, 4)
        let m = try ClientTransaction.material(html: html, indices: ind ?? [], source: "x-web")
        print("LIVE material anim key:", m.animationKey)
    }

    func testFullMaterialFetchLoggedOut() async throws {
        let m = try await TransactionMaterialFetcher(credentials: nil, config: .bundled).fetch()
        print("LIVE material source:", m.source, "anim:", m.animationKey)
    }
}
