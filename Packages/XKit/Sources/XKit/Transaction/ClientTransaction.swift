import Foundation

/// Material needed to generate `x-client-transaction-id` headers.
///
/// The iPhone computes this (it can afford to download x.com's HTML and JS)
/// and syncs it to the Watch. Only two short strings are needed afterwards.
public struct TransactionMaterial: Codable, Sendable, Equatable {
    /// Base64 `twitter-site-verification` meta content from the x.com page.
    public var verificationKey: String
    /// Derived from the loading-x-anim SVG frames + key-byte indices.
    public var animationKey: String
    public var fetchedAt: Date
    /// Which build the indices came from ("x-web" or "legacy"), for diagnostics.
    public var source: String

    public init(verificationKey: String, animationKey: String, fetchedAt: Date = Date(), source: String) {
        self.verificationKey = verificationKey
        self.animationKey = animationKey
        self.fetchedAt = fetchedAt
        self.source = source
    }
}

public enum TransactionError: Error, Equatable, Sendable {
    case verificationKeyNotFound
    case invalidVerificationKey
    case animationFramesNotFound
    case invalidAnimationData
    case indicesNotFound
    case signerScriptNotFound
}

/// Pure-Swift port of X's client transaction id algorithm.
///
/// Reference implementations (MIT): iSarabjitDhiman/XClientTransaction and
/// vladkens/twscrape `xclid.py`. The arithmetic deliberately mirrors the
/// Python reference (banker's rounding, `round(x, 2)`) so that unit tests can
/// compare against vectors produced by `scripts/gen_xclid_vectors.py`.
public enum ClientTransaction {
    public static let keyword = "obfiowerehiring"
    public static let additionalRandomNumber: UInt8 = 3
    public static let epochOffset: Int = 1_682_924_400
    static let totalTime = 4096.0

    // MARK: Material

    /// Builds the material from an x.com HTML page and the signer's key-byte indices.
    public static func material(html: String, indices: [Int], source: String, now: Date = Date()) throws -> TransactionMaterial {
        let key = try HTMLExtract.verificationKey(in: html)
        let frames = HTMLExtract.animationFrames(in: html)
        let anim = try animationKey(verificationKey: key, frames: frames, indices: indices)
        return TransactionMaterial(verificationKey: key, animationKey: anim, fetchedAt: now, source: source)
    }

    public static func keyBytes(_ verificationKey: String) throws -> [UInt8] {
        guard let d = Data(base64Encoded: verificationKey), !d.isEmpty else { throw TransactionError.invalidVerificationKey }
        return Array(d)
    }

    /// `frames` are the `d` attributes of the second `<path>` in each loading-x-anim SVG.
    public static func animationKey(verificationKey: String, frames: [String], indices: [Int]) throws -> String {
        let kb = try keyBytes(verificationKey)
        // Byte 5 picks the animation frame, so the key must be at least 6 bytes
        // (real keys are 48): a short/corrupt synced key must throw, not trap.
        guard kb.count >= 6 else { throw TransactionError.invalidVerificationKey }
        guard indices.count >= 2, indices.allSatisfy({ $0 >= 0 && $0 < kb.count }) else { throw TransactionError.indicesNotFound }
        guard !frames.isEmpty else { throw TransactionError.animationFramesNotFound }

        let d = frames[Int(kb[5]) % frames.count]
        let rows = parseFrameRows(d)
        let rowIndex = Int(kb[indices[0]]) % 16
        guard rowIndex < rows.count, rows[rowIndex].count >= 11 else { throw TransactionError.invalidAnimationData }

        var frameTime = 1
        for i in indices.dropFirst() { frameTime *= Int(kb[i]) % 16 }
        frameTime = Int((Double(frameTime) / 10 + 0.5).rounded(.down)) * 10  // JS Math.round to nearest 10

        return animate(frames: rows[rowIndex], targetTime: Double(frameTime) / totalTime)
    }

    /// `d[9:]` split on "C", every non-digit run becomes a separator.
    static func parseFrameRows(_ d: String) -> [[Double]] {
        let scalars = Array(d.unicodeScalars)
        guard scalars.count > 9 else { return [] }
        var tail = String.UnicodeScalarView()
        tail.append(contentsOf: scalars[9...])
        return String(tail).components(separatedBy: "C").map { part in
            var nums: [Double] = []
            var cur = ""
            for ch in part.unicodeScalars {
                if ch.value >= 48 && ch.value <= 57 { cur.unicodeScalars.append(ch) }
                else if !cur.isEmpty { nums.append(Double(cur)!); cur = "" }
            }
            if !cur.isEmpty { nums.append(Double(cur)!) }
            return nums
        }
    }

    static func animate(frames: [Double], targetTime: Double) -> String {
        let fromColor = [frames[0], frames[1], frames[2], 1.0]
        let toColor = [frames[3], frames[4], frames[5], 1.0]
        let toRotation = solve(frames[6], 60, 360, rounding: true)
        let curves = frames.dropFirst(7).enumerated().map { i, v in
            solve(v, i % 2 == 1 ? -1.0 : 0.0, 1.0, rounding: false)
        }
        let val = Cubic(curves: Array(curves)).value(at: targetTime)

        let color = zip(fromColor, toColor).map { a, b in max(0, min(255, a * (1 - val) + b * val)) }
        let rotation = 0.0 * (1 - val) + toRotation * val
        let rad = rotation * (Double.pi / 180.0)  // matches CPython math.radians
        let matrix = [cos(rad), -sin(rad), sin(rad), cos(rad)]

        var parts: [String] = color.dropLast().map { String(Int(pyRound($0)), radix: 16) }
        for v in matrix {
            var r = pyRound(v, digits: 2)
            if r < 0 { r = -r }
            let h = floatToHex(r)
            if h.hasPrefix(".") { parts.append("0" + h.lowercased()) }
            else if h.isEmpty { parts.append("0") }
            else { parts.append(h) }
        }
        parts += ["0", "0"]
        return parts.joined().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: "-", with: "")
    }

    static func solve(_ value: Double, _ minV: Double, _ maxV: Double, rounding: Bool) -> Double {
        let r = value * (maxV - minV) / 255 + minV
        return rounding ? r.rounded(.down) : pyRound(r, digits: 2)
    }

    /// Python 3 `round(x)`: round half to even.
    static func pyRound(_ x: Double) -> Double { x.rounded(.toNearestOrEven) }

    /// Python 3 `round(x, 2)`: correctly rounded based on the exact binary value.
    /// printf's `%.2f` is also correctly rounded (glibc and Apple libc), so use it.
    static func pyRound(_ x: Double, digits: Int) -> Double {
        let s = String(format: "%.\(digits)f", x)
        return Double(s) ?? x
    }

    /// Port of the reference `float_to_hex` (uppercase digits, "." separator).
    static func floatToHex(_ input: Double) -> String {
        var x = input
        var result: [Character] = []
        var quotient = Int(x)
        var fraction = x - Double(quotient)
        func digit(_ n: Int) -> Character {
            n > 9 ? Character(UnicodeScalar(UInt8(n + 55))) : Character(String(n))
        }
        while quotient > 0 {
            quotient = Int(x / 16)
            let remainder = Int(x - Double(quotient) * 16)
            result.insert(digit(remainder), at: 0)
            x = Double(quotient)
        }
        if fraction == 0 { return String(result) }
        result.append(".")
        var guardCount = 0
        while fraction > 0 && guardCount < 64 {
            fraction *= 16
            let integer = Int(fraction)
            fraction -= Double(integer)
            result.append(digit(integer))
            guardCount += 1
        }
        return String(result)
    }

    // MARK: Generation

    public static func transactionId(
        method: String, path: String, material: TransactionMaterial,
        now: Date = Date(), random: UInt8? = nil
    ) throws -> String {
        let ts = Int((now.timeIntervalSince1970 * 1000 - Double(epochOffset) * 1000) / 1000)
        return try transactionId(method: method, path: path, verificationKey: material.verificationKey,
                                 animationKey: material.animationKey, time: ts, random: random ?? UInt8.random(in: 0...255))
    }

    public static func transactionId(
        method: String, path: String, verificationKey: String, animationKey: String, time: Int, random: UInt8
    ) throws -> String {
        let kb = try keyBytes(verificationKey)
        let timeBytes: [UInt8] = (0..<4).map { UInt8((time >> ($0 * 8)) & 0xff) }
        let input = "\(method.uppercased())!\(path)!\(time)\(keyword)\(animationKey)"
        let hash = Hashing.sha256(Array(input.utf8))
        let payload = kb + timeBytes + hash.prefix(16) + [additionalRandomNumber]
        var out: [UInt8] = [random]
        out.reserveCapacity(payload.count + 1)
        for b in payload { out.append(b ^ random) }
        var s = Data(out).base64EncodedString()
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }
}

/// Cubic-bezier timing function (same as CSS `cubic-bezier()` solved by bisection).
struct Cubic {
    let curves: [Double]

    func value(at time: Double) -> Double {
        var startGradient = 0.0, endGradient = 0.0, start = 0.0, mid = 0.0, end = 1.0
        let c = curves.count >= 4 ? curves : curves + Array(repeating: 0, count: 4 - curves.count)
        if time <= 0 {
            if c[0] > 0 { startGradient = c[1] / c[0] }
            else if c[1] == 0 && c[2] > 0 { startGradient = c[3] / c[2] }
            return startGradient * time
        }
        if time >= 1 {
            if c[2] < 1 { endGradient = (c[3] - 1) / (c[2] - 1) }
            else if c[2] == 1 && c[0] < 1 { endGradient = (c[1] - 1) / (c[0] - 1) }
            return 1 + endGradient * (time - 1)
        }
        while start < end {
            mid = (start + end) / 2
            let xEst = Cubic.calculate(c[0], c[2], mid)
            if abs(time - xEst) < 0.00001 { return Cubic.calculate(c[1], c[3], mid) }
            if xEst < time { start = mid } else { end = mid }
        }
        return Cubic.calculate(c[1], c[3], mid)
    }

    static func calculate(_ a: Double, _ b: Double, _ m: Double) -> Double {
        3.0 * a * (1 - m) * (1 - m) * m + 3.0 * b * (1 - m) * m * m + m * m * m
    }
}

/// Minimal, dependency-free HTML scraping for the bits the algorithm needs.
public enum HTMLExtract {
    public static func verificationKey(in html: String) throws -> String {
        for tag in tags(named: "meta", in: html) where attribute("name", in: tag) == "twitter-site-verification" {
            if let c = attribute("content", in: tag), !c.isEmpty { return c }
        }
        throw TransactionError.verificationKeyNotFound
    }

    /// `d` of the 2nd `<path>` in each `<svg id="loading-x-anim-N">`, in document order.
    public static func animationFrames(in html: String) -> [String] {
        var out: [String] = []
        var searchStart = html.startIndex
        while let svgStart = html.range(of: "<svg", range: searchStart..<html.endIndex) {
            guard let tagEnd = html.range(of: ">", range: svgStart.upperBound..<html.endIndex) else { break }
            let openTag = String(html[svgStart.lowerBound..<tagEnd.upperBound])
            let close = html.range(of: "</svg>", range: tagEnd.upperBound..<html.endIndex)
            let bodyEnd = close?.lowerBound ?? html.endIndex
            searchStart = close?.upperBound ?? html.endIndex
            guard let id = attribute("id", in: openTag), id.hasPrefix("loading-x-anim") else { continue }
            let body = String(html[tagEnd.upperBound..<bodyEnd])
            let paths = tags(named: "path", in: body)
            if paths.count >= 2, let d = attribute("d", in: paths[1]) {
                out.append(d.trimmingCharacters(in: .whitespaces))
            }
        }
        return out
    }

    static func tags(named name: String, in html: String) -> [String] {
        var out: [String] = []
        var idx = html.startIndex
        let open = "<" + name
        while let r = html.range(of: open, options: .caseInsensitive, range: idx..<html.endIndex) {
            // Ensure it's the whole tag name (e.g. "<meta" not "<metadata").
            if r.upperBound < html.endIndex {
                let next = html[r.upperBound]
                if !(next == " " || next == ">" || next == "/" || next == "\n" || next == "\t") {
                    idx = r.upperBound; continue
                }
            }
            guard let end = html.range(of: ">", range: r.upperBound..<html.endIndex) else { break }
            out.append(String(html[r.lowerBound..<end.upperBound]))
            idx = end.upperBound
        }
        return out
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        for quote in ["\"", "'"] {
            let needle = " " + name + "=" + quote
            if let r = tag.range(of: needle, options: .caseInsensitive) {
                guard let end = tag.range(of: quote, range: r.upperBound..<tag.endIndex) else { return nil }
                return decode(String(tag[r.upperBound..<end.lowerBound]))
            }
        }
        return nil
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Key-byte indices from a signer script: every `(x[NN], 16)` occurrence.
    public static func signerIndices(in js: String) -> [Int] {
        // Equivalent of /(\(\w{1}\[(\d{1,2})\],\s*16\))+/g group 2.
        guard let re = try? NSRegularExpression(pattern: #"\(\w\[(\d{1,2})\],\s*16\)"#) else { return [] }
        let ns = js as NSString
        return re.matches(in: js, range: NSRange(location: 0, length: ns.length)).compactMap {
            Int(ns.substring(with: $0.range(at: 1)))
        }
    }
}

extension TransactionMaterial {
    /// Material that can actually produce a transaction id. Anything else is stored as
    /// absent (see `XSessionStore.setMaterial`), so it gets re-fetched instead of
    /// silently sending unsigned requests.
    public var isUsable: Bool {
        guard !animationKey.isEmpty, let bytes = try? ClientTransaction.keyBytes(verificationKey) else { return false }
        return bytes.count >= 6
    }
}
