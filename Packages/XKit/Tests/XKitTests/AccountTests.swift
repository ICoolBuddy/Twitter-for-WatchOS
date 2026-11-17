import XCTest
@testable import XKit

final class AccountTests: XCTestCase {
    private func creds(_ twid: String?, fill: String = "a") -> XCredentials {
        XCredentials(authToken: String(repeating: fill, count: 40),
                     ct0: String(repeating: "b", count: 64), twid: twid)
    }

    private func freshStore() -> XSessionStore {
        XSessionStore(keychain: KeychainStore(service: "test-\(UUID().uuidString)"), directory: nil)
    }

    func testLegacySessionMigratesToAccount() async throws {
        let keychain = KeychainStore(service: "test-\(UUID().uuidString)")
        let legacy = creds("u%3D12345")
        try keychain.saveCredentials(legacy)
        XCTAssertNotNil(keychain.loadCredentials())

        let store = XSessionStore(keychain: keychain, directory: nil)
        let accounts = await store.accounts
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.id, "12345")
        XCTAssertEqual(accounts.first?.credentials, legacy)
        let active = await store.activeAccountId
        XCTAssertEqual(active, "12345")
        let activeCreds = await store.credentials
        XCTAssertEqual(activeCreds, legacy)
        // The legacy single-session key is deleted after migration.
        XCTAssertNil(keychain.loadCredentials())
    }

    func testAccountUpsertSwitchRemoveReplace() async {
        let store = freshStore()
        let a = creds("u%3D111", fill: "a")
        let b = creds("u%3D222", fill: "c")

        let idA = await store.upsertAccount(a, user: nil)
        let idB = await store.upsertAccount(b, user: nil)
        XCTAssertEqual(idA, "111")
        XCTAssertEqual(idB, "222")
        var accounts = await store.accounts
        XCTAssertEqual(accounts.map(\.id), ["111", "222"])
        var activeId = await store.activeAccountId
        XCTAssertEqual(activeId, "222")
        var activeCreds = await store.credentials
        XCTAssertEqual(activeCreds?.authToken, b.authToken)

        // Upserting the same account updates it without duplicating.
        let rotated = XCredentials(authToken: a.authToken, ct0: String(repeating: "d", count: 64), twid: "u%3D111")
        _ = await store.upsertAccount(rotated, user: nil)
        accounts = await store.accounts
        XCTAssertEqual(accounts.count, 2)
        activeCreds = await store.credentials
        XCTAssertEqual(activeCreds?.ct0, rotated.ct0)

        let user = XUser(id: "111", name: "Ada", screenName: "ada")
        await store.updateUser(user, forAccount: "111")
        accounts = await store.accounts
        XCTAssertEqual(accounts.first { $0.id == "111" }?.user?.name, "Ada")

        await store.setActiveAccount("111")
        activeId = await store.activeAccountId
        XCTAssertEqual(activeId, "111")

        // Removing the active account falls back to the next one.
        await store.removeAccount("111")
        accounts = await store.accounts
        XCTAssertEqual(accounts.map(\.id), ["222"])
        activeId = await store.activeAccountId
        XCTAssertEqual(activeId, "222")
        activeCreds = await store.credentials
        XCTAssertEqual(activeCreds?.authToken, b.authToken)

        // replaceAccounts keeps the current active account when it is still present.
        let c = XAccount(credentials: creds("u%3D333", fill: "e"))
        await store.replaceAccounts([c, XAccount(credentials: b)])
        activeId = await store.activeAccountId
        XCTAssertEqual(activeId, "222")

        // …and falls back to the first when it disappears.
        await store.replaceAccounts([c])
        activeId = await store.activeAccountId
        XCTAssertEqual(activeId, "333")

        // An empty list is logged out.
        await store.replaceAccounts([])
        accounts = await store.accounts
        XCTAssertTrue(accounts.isEmpty)
        activeId = await store.activeAccountId
        XCTAssertNil(activeId)
        let none = await store.credentials
        XCTAssertNil(none)
    }

    func testAccountIDFallbackIsStableHash() {
        let c = creds(nil, fill: "e")
        XCTAssertNil(c.userId)
        let id = XAccount.id(for: c)
        XCTAssertTrue(id.hasPrefix("local-"), id)
        XCTAssertEqual(id.count, 22) // "local-" + 16 hex chars (8 bytes)
        let hex = String(id.dropFirst("local-".count))
        XCTAssertTrue(hex.allSatisfy { "0123456789abcdef".contains($0) }, hex)
        XCTAssertEqual(XAccount.id(for: c), id)
        XCTAssertEqual(XAccount(credentials: c).id, id)
    }

    func testSyncPayloadRoundTripWithAccounts() throws {
        let account = XAccount(credentials: creds("u%3D42"),
                               user: XUser(id: "42", name: "Ada", screenName: "ada"))
        let payload = SyncPayload(command: .update, accounts: [account])
        let back = try XCTUnwrap(SyncPayload.from(dictionary: payload.dictionary()))
        XCTAssertEqual(back.accounts, [account])
    }

    func testSyncPayloadDecodesWithoutAccounts() throws {
        let json = #"{"command":"update","credentials":{"authToken":"aaaa","ct0":"bbbb"},"sentAt":"2026-11-17T10:00:00Z"}"#
        let payload = try SyncPayload.decode(Data(json.utf8))
        XCTAssertNil(payload.accounts)
        XCTAssertEqual(payload.credentials?.authToken, "aaaa")
    }

    func testSyncPayloadAppliesAccounts() async {
        let store = freshStore()
        let account = XAccount(credentials: creds("u%3D777", fill: "f"))
        await SyncPayload(command: .update, accounts: [account]).apply(to: store)
        let accounts = await store.accounts
        XCTAssertEqual(accounts.map(\.id), ["777"])
        let activeId = await store.activeAccountId
        XCTAssertEqual(activeId, "777")

        // An empty accounts list means logged out.
        await SyncPayload(command: .update, accounts: []).apply(to: store)
        let empty = await store.accounts
        XCTAssertTrue(empty.isEmpty)
        let none = await store.credentials
        XCTAssertNil(none)
    }

    func testPlaybackURLSelection() {
        func url(_ s: String) -> URL { URL(string: "https://video.twimg.com/\(s).mp4")! }
        func media(_ variants: [XVideoVariant]) -> XMedia {
            XMedia(id: "1", type: .video, url: URL(string: "https://pbs.twimg.com/media/1.jpg")!,
                   width: 1280, height: 720, variants: variants)
        }
        let low = XVideoVariant(url: url("low"), bitrate: 100_000, contentType: "video/mp4")
        let mid = XVideoVariant(url: url("mid"), bitrate: 600_000, contentType: "video/mp4")
        let high = XVideoVariant(url: url("high"), bitrate: 2_000_000, contentType: "video/mp4")
        let hls = XVideoVariant(url: URL(string: "https://video.twimg.com/playlist.m3u8")!,
                                bitrate: nil, contentType: "application/x-mpegURL")

        // Best MP4 under the cap.
        XCTAssertEqual(media([low, mid, high, hls]).playbackURL()?.absoluteString, mid.url.absoluteString)
        // Nothing under the cap → the lowest-bitrate MP4.
        let tooBig = media([high, XVideoVariant(url: url("huge"), bitrate: 3_000_000, contentType: "video/mp4")])
        XCTAssertEqual(tooBig.playbackURL(maxBitrate: 10)?.absoluteString, high.url.absoluteString)
        // No MP4 at all → HLS.
        XCTAssertEqual(media([hls]).playbackURL()?.absoluteString, hls.url.absoluteString)
        // Animated GIF: one MP4 variant with bitrate 0.
        let gifMP4 = XVideoVariant(url: url("gif"), bitrate: 0, contentType: "video/mp4")
        let gif = XMedia(id: "2", type: .gif, url: URL(string: "https://pbs.twimg.com/tweet_video/2.jpg")!,
                         width: 320, height: 240, variants: [gifMP4])
        XCTAssertEqual(gif.playbackURL()?.absoluteString, gifMP4.url.absoluteString)

        XCTAssertEqual(media([mid]).previewURL.absoluteString.contains("name=240x240"), true)
        XCTAssertEqual(media([mid]).feedURL.absoluteString.contains("name=small"), true)
        XCTAssertEqual(media([mid]).fullURL.absoluteString.contains("name=medium"), true)
    }
}
