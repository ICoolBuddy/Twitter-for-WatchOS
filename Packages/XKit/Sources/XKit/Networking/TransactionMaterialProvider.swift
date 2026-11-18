import Foundation

/// Fetches and caches the `x-client-transaction-id` material. One instance per app:
/// the only place that downloads the signer (single-flight, staleness), used by both the
/// client's 404 retry and the manual "Refresh signing key".
public actor TransactionMaterialProvider {
    private let store: XSessionStore
    private let transport: HTTPTransport
    private var inFlight: Task<TransactionMaterial, Error>?

    public init(store: XSessionStore, transport: HTTPTransport = URLSessionTransport()) {
        self.store = store
        self.transport = transport
    }

    /// Stored material younger than `maxAge`, or a fresh download (`force` skips the
    /// cache). Concurrent callers share one download. A cancelled caller cancels the
    /// download (`Task.value` alone would not), so a screen that went away stops it.
    ///
    /// How often X rotates the key is unverified; the request log's `MATERIAL` rows and
    /// the "· material <age>" note on 403/404 rows measure it on the device.
    @discardableResult
    public func material(maxAge: TimeInterval = 7 * 86_400, force: Bool = false) async throws -> TransactionMaterial {
        if !force, let m = await store.material, Date().timeIntervalSince(m.fetchedAt) < maxAge { return m }
        if let t = inFlight { return try await t.value }
        let creds = await store.credentials
        let config = await store.config
        let previousAge = await store.material.map { RelativeTime.short($0.fetchedAt) } ?? "none"
        let started = Date()
        let transport = transport
        let t = Task {
            try await TransactionMaterialFetcher(transport: transport, credentials: creds, config: config).fetch()
        }
        inFlight = t
        do {
            let m = try await withTaskCancellationHandler { try await t.value } onCancel: { t.cancel() }
            inFlight = nil
            await store.setMaterial(m)
            await RequestLog.shared.record(method: "MATERIAL", url: nil, status: 200,
                                           durationMs: Int(Date().timeIntervalSince(started) * 1000),
                                           note: "new material source=\(m.source) previous=\(previousAge)")
            return m
        } catch {
            inFlight = nil
            throw error
        }
    }
}
