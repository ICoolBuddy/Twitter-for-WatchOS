import Foundation

/// Fetches and caches the `x-client-transaction-id` material. One instance per app:
/// the only place that downloads the signer (single-flight, staleness), used by both the
/// client's 404 retry and the manual "Refresh signing key".
public actor TransactionMaterialProvider {
    private let store: XSessionStore
    private let transport: HTTPTransport
    /// The one download in progress, with the id of the call that started it.
    private var inFlight: (id: UUID, task: Task<TransactionMaterial, Error>)?

    public init(store: XSessionStore, transport: HTTPTransport = URLSessionTransport()) {
        self.store = store
        self.transport = transport
    }

    /// Stored material younger than `maxAge`, or a fresh download (`force` skips the
    /// cache). Concurrent callers share one download; a caller going away only stops
    /// waiting (it must not cancel the download everyone else is awaiting), and the
    /// task that performs the download stores the result itself, so it lands even when
    /// the caller that started it is gone.
    ///
    /// How often X rotates the key is unverified; the request log's `MATERIAL` rows and
    /// the "· material <age>" note on 403/404 rows measure it on the device.
    @discardableResult
    public func material(maxAge: TimeInterval = 7 * 86_400, force: Bool = false) async throws -> TransactionMaterial {
        if !force, let m = await store.material, Date().timeIntervalSince(m.fetchedAt) < maxAge { return m }

        if let existing = inFlight {
            return try await existing.task.value
        }
        // No await between reading `inFlight` and storing the new task: two callers
        // cannot each start a full scrape (the old check left four suspension points).
        let id = UUID()
        let store = self.store
        let transport = self.transport
        let task = Task { [weak self] in
            do {
                let creds = await store.credentials
                let config = await store.config
                let m = try await TransactionMaterialFetcher(transport: transport,
                                                             credentials: creds,
                                                             config: config).fetch()
                await self?.finish(id: id, material: m)
                return m
            } catch {
                await self?.finish(id: id, material: nil)
                throw error
            }
        }
        inFlight = (id, task)
        return try await task.value
    }

    /// Called by the download task itself, so the result is stored exactly once and the
    /// slot is freed even when no caller is left to collect it.
    private func finish(id: UUID, material m: TransactionMaterial?) async {
        guard inFlight?.id == id else { return }
        inFlight = nil
        guard let m else { return }
        let previousAge = await store.material.map { RelativeTime.short($0.fetchedAt) } ?? "none"
        await store.setMaterial(m)
        await RequestLog.shared.record(method: "MATERIAL", url: nil, status: 200, durationMs: 0,
                                       note: "new material source=\(m.source) previous=\(previousAge)")
    }
}
