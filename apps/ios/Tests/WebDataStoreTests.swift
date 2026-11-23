import XCTest
import WebKit
@testable import WeQRemote

final class WebDataStoreTests: XCTestCase {
    func testInstantSnapshotExpiresAndCannotCrossAuthorizationOrAccount() async throws {
        let token = UUID().uuidString
        let other = UUID().uuidString
        defer { RemoteInstantStore.clear(token); RemoteInstantStore.clear(other) }
        let now = Date().timeIntervalSince1970 * 1000
        let chat = RemoteInstantSnapshot.Chat(id: "chat", title: "Synthetic", expiresAt: now + 60_000,
            rows: [.init(id: "row", text: "Cached", mine: false)])
        let first = RemoteInstantSnapshot(scope: "first", chats: [chat])
        let data = try JSONEncoder().encode(first)
        XCTAssertNil(RemoteInstantSnapshot.decode(data)?.current(now: now + 61_000))
        RemoteInstantStore.update(String(decoding: data, as: UTF8.self), token: token)
        let stored = await RemoteInstantStore.load(token)
        let unrelated = await RemoteInstantStore.load(other)
        XCTAssertEqual(stored, first)
        XCTAssertNil(unrelated)
        RemoteInstantStore.update(#"{"scope":"first"}"#, token: token)
        let sameScope = await RemoteInstantStore.load(token)
        XCTAssertEqual(sameScope, first)
        RemoteInstantStore.update(#"{"scope":"second"}"#, token: token)
        let switchedScope = await RemoteInstantStore.load(token)
        XCTAssertNil(switchedScope)
        RemoteInstantStore.update(String(decoding: data, as: UTF8.self), token: token)
        RemoteInstantStore.clear(token)
        let revoked = await RemoteInstantStore.load(token)
        XCTAssertNil(revoked)
    }

    @MainActor
    func testBusinessSnapshotsSurviveNewRouteAndDoNotCrossScopeOrRevocation() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = RemoteBusinessCache(directory: directory)
        await first.put(scope: "account-a", payload: "new snapshot", savedAt: 10)
        await first.put(scope: "account-a", payload: "late stale snapshot", savedAt: 9)
        await first.put(scope: "account-a", kind: .avatar, payload: "image", savedAt: 9)
        let next = RemoteBusinessCache(directory: directory)
        let snapshot = await next.get(scope: "account-a")
        let avatar = await next.get(scope: "account-a", kind: .avatar)
        let unrelated = await next.get(scope: "account-b")
        let unchanged = await next.get(scope: "account-a", newerThan: 10)
        XCTAssertEqual(snapshot, "new snapshot")
        XCTAssertEqual(avatar, "image")
        XCTAssertNil(unrelated)
        XCTAssertNil(unchanged)
        first.clear()
        await first.put(scope: "account-a", payload: "late session", savedAt: 11)
        let revoked = await next.get(scope: "account-a")
        XCTAssertNil(revoked)
    }

    @MainActor
    func testReconnectReusesOnlyTheSameComputerAndAuthorization() async {
        let cache = RemoteWebDataStore()
        let endpoint = URL(string: "https://192.168.1.8:7691")!
        let token = String(repeating: "a", count: 64)
        let pin = String(repeating: "f", count: 64)
        let first = cache.dataStore(endpoint: endpoint, token: token, fingerprint: pin)
        if #available(macOS 14.0, iOS 17.0, *) {
            XCTAssertTrue(first.isPersistent)
            let restarted = RemoteWebDataStore().dataStore(endpoint: endpoint, token: token, fingerprint: pin)
            XCTAssertEqual(first.identifier, restarted.identifier)
        }
        XCTAssertTrue(first === cache.dataStore(endpoint: endpoint, token: token, fingerprint: pin))
        let next = cache.dataStore(endpoint: endpoint, token: String(repeating: "b", count: 64), fingerprint: pin)
        XCTAssertFalse(first === next)
        let changedPin = cache.dataStore(endpoint: endpoint, token: String(repeating: "b", count: 64), fingerprint: nil)
        XCTAssertFalse(next === changedPin)
        let changedComputer = cache.dataStore(endpoint: URL(string: "https://192.168.1.9:7691")!, token: token, fingerprint: pin)
        XCTAssertFalse(changedPin === changedComputer)
        let cookie = HTTPCookie(properties: [.domain: "192.168.1.9", .path: "/", .name: "synthetic", .value: "test"])!
        await changedComputer.httpCookieStore.setCookie(cookie)
        await withCheckedContinuation { continuation in cache.clear { continuation.resume() } }
        let cookies = await changedComputer.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty)
        let cleared = cache.dataStore(endpoint: URL(string: "https://192.168.1.9:7691")!, token: token, fingerprint: pin)
        if #available(macOS 14.0, iOS 17.0, *) { XCTAssertEqual(changedComputer.identifier, cleared.identifier) }
        cache.clear()
    }
}
