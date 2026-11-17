import Foundation
@testable import XKit

enum Fixtures {
    static func url(_ name: String) throws -> URL {
        guard let base = Bundle.module.resourceURL else { throw CocoaError(.fileNoSuchFile) }
        let candidates = [base.appendingPathComponent("Fixtures").appendingPathComponent(name),
                          base.appendingPathComponent(name)]
        for c in candidates where FileManager.default.fileExists(atPath: c.path) { return c }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name])
    }

    static func data(_ name: String) throws -> Data { try Data(contentsOf: url(name)) }
    static func string(_ name: String) throws -> String { String(decoding: try data(name), as: UTF8.self) }
    static func json(_ name: String) throws -> JSON { try JSON(data: data(name)) }
}
