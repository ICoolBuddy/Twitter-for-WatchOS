import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Simple GET helper over an `HTTPTransport`.
struct Fetcher: Sendable {
    let transport: HTTPTransport
    var cookieHeader: String?

    func text(_ url: URL) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(LiveXClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/javascript,*/*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if let cookieHeader, url.host?.hasSuffix("x.com") == true { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        let start = Date()
        let (data, resp) = try await transport.send(req)
        await RequestLog.shared.record(method: "GET", url: url, status: resp.statusCode,
                                       durationMs: Int(Date().timeIntervalSince(start) * 1000), note: "scrape")
        guard (200..<300).contains(resp.statusCode) else { throw XError.server(resp.statusCode) }
        return String(decoding: data, as: UTF8.self)
    }
}

enum Regex {
    static func matches(_ pattern: String, in s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    static func first(_ pattern: String, in s: String) -> [String]? { matches(pattern, in: s).first }

    static func matchesWithRanges(_ pattern: String, in s: String) -> [([String], NSRange)] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            ((0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }, m.range)
        }
    }

    static func ranges(_ literal: String, in s: String) -> [NSRange] {
        let ns = s as NSString
        var out: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while true {
            let r = ns.range(of: literal, options: [], range: search)
            if r.location == NSNotFound { break }
            out.append(r)
            let next = r.location + r.length
            search = NSRange(location: next, length: ns.length - next)
        }
        return out
    }
}

/// Finds current GraphQL query IDs + feature flags by reading x.com's public
/// legacy web bundle — the same thing `scripts/update_endpoints.py` does.
public struct EndpointDiscovery: Sendable {
    let fetcher: Fetcher
    /// Upper bound on chunk downloads so a phone never pulls the whole site.
    public var maxChunks = EndpointDiscovery.defaultMaxChunks
    /// The Watch has far less time, battery and RAM than the phone.
    public static var defaultMaxChunks: Int {
        #if os(watchOS)
        return 25
        #else
        return 80
        #endif
    }

    public init(transport: HTTPTransport = URLSessionTransport()) {
        self.fetcher = Fetcher(transport: transport, cookieHeader: nil)
    }

    static let shellURL = URL(string: "https://x.com/i/embed")!
    static let opPattern =
        #"queryId:"([^"]+)",operationName:"([^"]+)",operationType:"([a-z]+)",metadata:\{featureSwitches:\[([^\]]*)\],fieldToggles:\[([^\]]*)\]"#
    /// Chunk names likely to hold ops not in main.js (Home, Notifications, Bookmarks, Likes).
    static let priorityHints = ["Notifications", "Bookmarks", "Likes", "AudioSpacePeek", "ComposeMedia", "Home"]

    public func discover(base: EndpointConfig) async throws -> EndpointConfig {
        let html = try await fetcher.text(Self.shellURL)
        let features = Self.featureDefaults(html)
        var scripts = Self.legacyScripts(html)
        guard !scripts.isEmpty else { throw XError.decoding("No scripts found on x.com page") }
        scripts.sort { Self.priority($0) < Self.priority($1) }

        let wanted = Set(Operation.allCases.map(\.rawValue))
        var found: [String: OperationInfo] = [:]
        var legacyIndices: [Int] = []

        for (i, url) in scripts.enumerated() where i < maxChunks {
            if found.count == wanted.count, !legacyIndices.isEmpty { break }
            if found.count == wanted.count, !url.absoluteString.contains("ondemand.s.") { continue }
            guard let js = try? await fetcher.text(url) else { continue }
            for (name, info) in Self.operations(in: js) where wanted.contains(name) && found[name] == nil {
                found[name] = info
            }
            if url.absoluteString.contains("/ondemand.s.") { legacyIndices = HTMLExtract.signerIndices(in: js) }
        }
        guard !found.isEmpty else { throw XError.decoding("No GraphQL operations found") }

        let used = Set(found.values.flatMap(\.features))
        var values: [String: Bool] = [:]
        for f in used { values[f] = features[f] ?? base.featureValues[f] ?? false }

        let iso = ISO8601DateFormatter().string(from: Date())
        let discovered = EndpointConfig(
            updatedAt: iso, bearer: base.bearer, graphqlBase: base.graphqlBase, operations: found,
            featureValues: values, signer: nil,
            legacySigner: legacyIndices.isEmpty ? nil : SignerInfo(indices: legacyIndices, source: "legacy"))
        return base.merging(discovered)
    }

    static func priority(_ url: URL) -> Int {
        let s = url.lastPathComponent
        if s.hasPrefix("main.") { return 0 }
        if s.hasPrefix("ondemand.s.") { return 1 }
        if priorityHints.contains(where: { s.contains("bundle." + $0) }) { return 2 }
        if s.hasPrefix("bundle.") { return 3 }
        if s.hasPrefix("shared~") && s.contains("bundle.") { return 4 }
        return 5
    }

    public static func operations(in js: String) -> [String: OperationInfo] {
        var out: [String: OperationInfo] = [:]
        for m in Regex.matches(opPattern, in: js) where m.count == 6 {
            let names = { (s: String) in Regex.matches(#""([^"]+)""#, in: s).map { $0[1] } }
            out[m[2]] = OperationInfo(queryId: m[1], type: m[3], features: names(m[4]), fieldToggles: names(m[5]))
        }
        return out
    }

    public static func legacyScripts(_ html: String) -> [URL] {
        var urls = Regex.matches(#"https://abs\.twimg\.com/responsive-web/client-web/[\w.~-]+\.js"#, in: html).map { $0[0] }
        var hashes: [String: String] = [:]
        var names: [String: String] = [:]
        for m in Regex.matches(#"(\d+):"([^"]+)""#, in: html) {
            let v = m[2]
            let isHash = (v.count == 7 || v.count == 16) && v.allSatisfy { "0123456789abcdef".contains($0) }
            if isHash { hashes[m[1]] = v } else { names[m[1]] = v }
        }
        for (k, h) in hashes.sorted(by: { $0.key < $1.key }) {
            urls.append("https://abs.twimg.com/responsive-web/client-web/\(names[k] ?? k).\(h)a.js")
        }
        var seen = Set<String>()
        return urls.filter { u in
            guard !seen.contains(u) else { return false }
            seen.insert(u)
            return !(u.contains("/i18n/") || u.contains("countries-") || u.contains("emoji") || u.contains("icons"))
        }.compactMap(URL.init(string:))
    }

    public static func featureDefaults(_ html: String) -> [String: Bool] {
        var out: [String: Bool] = [:]
        guard let start = html.range(of: #""featureSwitch":{"defaultConfig":"#) else { return out }
        let tail = html[start.upperBound...].prefix(400_000)
        for m in Regex.matches(#""([a-z0-9_]+)":\{"value":(true|false)\}"#, in: String(tail)) {
            if out[m[1]] == nil { out[m[1]] = m[2] == "true" }
        }
        return out
    }
}

/// Downloads an x.com page + the signer script and computes `TransactionMaterial`.
///
/// Current (Nov 2026) layouts handled:
/// - x-web (Vite) app: signer is a dynamically imported chunk (`sign.o-*.js` when
///   logged in, a hashed name next to the `x-client-transaction-id` header plugin
///   otherwise). Identified by its `(e[NN],16)` index pattern.
/// - legacy responsive-web app: `ondemand.s.<hash>a.js` from the chunk map.
public struct TransactionMaterialFetcher: Sendable {
    let fetcher: Fetcher
    let fallbackSigner: SignerInfo?
    let fallbackLegacySigner: SignerInfo?
    public var maxChunkScans = TransactionMaterialFetcher.defaultMaxChunkScans
    public static var defaultMaxChunkScans: Int {
        #if os(watchOS)
        return 12
        #else
        return 40
        #endif
    }

    public init(transport: HTTPTransport = URLSessionTransport(), credentials: XCredentials?, config: EndpointConfig) {
        self.fetcher = Fetcher(transport: transport, cookieHeader: credentials?.cookieHeader)
        self.fallbackSigner = config.signer
        self.fallbackLegacySigner = config.legacySigner
    }

    public func fetch() async throws -> TransactionMaterial {
        var lastError: Error = TransactionError.verificationKeyNotFound
        // Logged-in x-web page first (matches what twscrape uses), then the legacy shell.
        for page in ["https://x.com/home", "https://x.com/i/embed"] {
            do {
                let html = try await fetcher.text(URL(string: page)!)
                guard (try? HTMLExtract.verificationKey(in: html)) != nil,
                      !HTMLExtract.animationFrames(in: html).isEmpty else { continue }
                let (indices, source) = try await signerIndices(pageHTML: html)
                return try ClientTransaction.material(html: html, indices: indices, source: source)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func signerIndices(pageHTML html: String) async throws -> ([Int], String) {
        // Legacy build: ondemand.s chunk id → hash.
        if let idx = Regex.first(#",(\d+):["']ondemand\.s["']"#, in: html)?[1],
           let hash = Regex.first(",\(idx):\"([0-9a-f]+)\"", in: html)?[1],
           let url = URL(string: "https://abs.twimg.com/responsive-web/client-web/ondemand.s.\(hash)a.js"),
           let js = try? await fetcher.text(url) {
            let ind = HTMLExtract.signerIndices(in: js)
            if ind.count >= 2 { return (ind, "legacy") }
        }

        // x-web build.
        let scripts = Regex.matches(#"https://[\w.-]+/x-web/[\w./-]+\.js"#, in: html).map { $0[0] }
        if !scripts.isEmpty {
            if let found = try await scanXWeb(scripts: scripts) { return (found, "x-web") }
            if let s = fallbackSigner, !s.indices.isEmpty { return (s.indices, s.source + "-fallback") }
        }
        if let s = fallbackLegacySigner, !s.indices.isEmpty { return (s.indices, "legacy-fallback") }
        if let s = fallbackSigner, !s.indices.isEmpty { return (s.indices, s.source + "-fallback") }
        throw TransactionError.signerScriptNotFound
    }

    /// BFS over x-web chunks starting at the page's scripts, preferring chunks that
    /// reference the transaction-id header, until a script with signer indices is found.
    func scanXWeb(scripts: [String]) async throws -> [Int]? {
        var queue = scripts.compactMap(URL.init(string:))
        var seen = Set(queue)
        var scanned = 0
        while !queue.isEmpty, scanned < maxChunkScans {
            let url = queue.removeFirst()
            scanned += 1
            guard let js = try? await fetcher.text(url) else { continue }
            let ind = HTMLExtract.signerIndices(in: js)
            if ind.count >= 2, js.contains("1682924400") { return ind }

            var direct: [URL] = []
            var hinted: [URL] = []
            var others: [URL] = []
            for m in Regex.matches(#"["'`]((?:\.{0,2}/)?[\w./-]*?\b(?:sign\.o|ondemand\.s)[\w.-]*\.js)["'`]"#, in: js) {
                if let u = URL(string: m[1], relativeTo: url)?.absoluteURL { direct.append(u) }
            }
            // Dynamic imports close to the transaction-id header plugin are the signer candidates.
            let txPositions = Regex.ranges("client-transaction-id", in: js).map(\.location)
            for (m, r) in Regex.matchesWithRanges(#"import\(\s*["'`](\.{1,2}/[\w.-]+\.js)["'`]\s*\)"#, in: js) {
                guard let u = URL(string: m[1], relativeTo: url)?.absoluteURL else { continue }
                let near = txPositions.contains { abs($0 - r.location) < 4000 }
                if near { hinted.append(u) } else { others.append(u) }
            }
            // Static imports and Vite preload maps ("./X.js", "assets/X.js").
            for m in Regex.matches(#"["'`]((?:\.{1,2}/)?(?:assets/)?[\w-]{6,24}\.js)["'`]"#, in: js) {
                if let u = Self.resolve(m[1], from: url) { others.append(u) }
            }
            // Direct & hinted candidates jump the queue.
            for u in (direct + hinted).reversed() where !seen.contains(u) { seen.insert(u); queue.insert(u, at: 0) }
            for u in others where !seen.contains(u) { seen.insert(u); queue.append(u) }
        }
        return nil
    }

    /// Vite emits paths relative to the importing chunk ("./X.js") or to the app
    /// base ("assets/X.js").
    static func resolve(_ ref: String, from url: URL) -> URL? {
        if ref.hasPrefix("assets/"), let r = url.absoluteString.range(of: "/x-web/x-web/") {
            return URL(string: String(url.absoluteString[..<r.upperBound]) + ref)
        }
        return URL(string: ref, relativeTo: url)?.absoluteURL
    }
}
