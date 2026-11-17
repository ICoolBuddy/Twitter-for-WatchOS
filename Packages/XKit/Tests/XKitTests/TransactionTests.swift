import XCTest
@testable import XKit

final class TransactionTests: XCTestCase {
    struct Vector: Decodable {
        struct Tx: Decodable { let method: String; let path: String; let time: Int; let random: UInt8; let id: String }
        let fixture: String
        let indices: [Int]
        let verificationKey: String
        let frameTime: Int
        let frameRow: [Double]
        let animationKey: String
        let transactions: [Tx]
    }

    func loadVectors() throws -> [Vector] {
        let data = try Fixtures.data("xclid_vectors.json")
        return try JSONDecoder().decode([Vector].self, from: data)
    }

    func testSHA256Portable() {
        let empty = PortableSHA256.hash([])
        XCTAssertEqual(empty.map { String(format: "%02x", $0) }.joined(),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let abc = PortableSHA256.hash(Array("abc".utf8))
        XCTAssertEqual(abc.map { String(format: "%02x", $0) }.joined(),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Array(String(repeating: "a", count: 1000).utf8)
        XCTAssertEqual(PortableSHA256.hash(long), Hashing.sha256(long))
    }

    func testFloatToHex() {
        XCTAssertEqual(ClientTransaction.floatToHex(0), "")
        XCTAssertEqual(ClientTransaction.floatToHex(1), "1")
        XCTAssertEqual(ClientTransaction.floatToHex(0.5), ".8")
        XCTAssertEqual(ClientTransaction.floatToHex(255), "FF")
        XCTAssertEqual(ClientTransaction.floatToHex(0.25), ".4")
    }

    func testPythonRounding() {
        XCTAssertEqual(ClientTransaction.pyRound(2.5), 2)
        XCTAssertEqual(ClientTransaction.pyRound(3.5), 4)
        XCTAssertEqual(ClientTransaction.pyRound(2.675, digits: 2), 2.67)  // binary 2.67499999…
        XCTAssertEqual(ClientTransaction.pyRound(-0.4999, digits: 2), -0.5)
    }

    func testHTMLExtraction() throws {
        for v in try loadVectors() {
            let html = try Fixtures.string(v.fixture)
            XCTAssertEqual(try HTMLExtract.verificationKey(in: html), v.verificationKey)
            let frames = HTMLExtract.animationFrames(in: html)
            XCTAssertEqual(frames.count, 4, v.fixture)
        }
    }

    func testAnimationKeyMatchesReference() throws {
        for v in try loadVectors() {
            let html = try Fixtures.string(v.fixture)
            let m = try ClientTransaction.material(html: html, indices: v.indices, source: "test")
            XCTAssertEqual(m.animationKey, v.animationKey, v.fixture)
        }
    }

    func testTransactionIdsMatchReference() throws {
        for v in try loadVectors() {
            for tx in v.transactions {
                let id = try ClientTransaction.transactionId(
                    method: tx.method, path: tx.path, verificationKey: v.verificationKey,
                    animationKey: v.animationKey, time: tx.time, random: tx.random)
                XCTAssertEqual(id, tx.id, "\(v.fixture) \(tx.method) \(tx.path)")
            }
        }
    }

    func testTransactionIdRoundTripStructure() throws {
        let v = try loadVectors()[0]
        let m = TransactionMaterial(verificationKey: v.verificationKey, animationKey: v.animationKey, source: "t")
        let id = try ClientTransaction.transactionId(method: "get", path: "/x", material: m, random: 42)
        var b64 = id
        while b64.count % 4 != 0 { b64 += "=" }
        let bytes = Array(Data(base64Encoded: b64)!)
        XCTAssertEqual(bytes[0], 42)
        let decoded = bytes.dropFirst().map { $0 ^ 42 }
        let kb = try ClientTransaction.keyBytes(v.verificationKey)
        XCTAssertEqual(Array(decoded.prefix(kb.count)), kb)
        XCTAssertEqual(decoded.last, 3)
        XCTAssertEqual(decoded.count, kb.count + 4 + 16 + 1)
    }

    func testSignerIndicesRegex() {
        let js = "var a=parseInt(e[35],16),b=(e[42], 16)*x(e[37],16);q=(W[10],16)"
        XCTAssertEqual(HTMLExtract.signerIndices(in: js), [35, 42, 37, 10])
    }
}
