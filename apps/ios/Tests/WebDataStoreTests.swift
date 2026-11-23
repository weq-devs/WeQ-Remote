import XCTest
import CryptoKit
import WebKit
@testable import WeQRemote

final class WebDataStoreTests: XCTestCase {
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
        await next.put(scope: "account-a", kind: .avatar, payload: "late image", savedAt: 11)
        let revoked = await next.get(scope: "account-a")
        XCTAssertNil(revoked)
        let fresh = RemoteBusinessCache(directory: directory)
        let purgedAvatar = await fresh.get(scope: "account-a", kind: .avatar)
        XCTAssertNil(purgedAvatar)
        await fresh.put(scope: "account-a", payload: "new authorization generation", savedAt: 12)
        next.clear()
        let replaced = await fresh.get(scope: "account-a")
        XCTAssertEqual(replaced, "new authorization generation")
    }

    @MainActor
    func testRevalidatesAnAtomicallyReplacedSnapshotAndDoesNotReuseDeletedTimestamps() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RemoteBusinessCache(directory: directory)
        let scope = "fixture"
        let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent("business").appendingPathComponent(hash)
        await cache.put(scope: scope, payload: "old", savedAt: 100)
        let stale = await cache.get(scope: scope, newerThan: 400)
        XCTAssertNil(stale)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        let replacement = try JSONSerialization.data(withJSONObject: ["savedAt": 900, "payload": "new"])
        try replacement.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let restored = await cache.get(scope: scope, newerThan: 400)
        XCTAssertEqual(restored, "new")
        try FileManager.default.removeItem(at: file)
        await cache.put(scope: scope, payload: "rebuilt after eviction", savedAt: 200)
        let rebuilt = await cache.get(scope: scope)
        XCTAssertEqual(rebuilt, "rebuilt after eviction")
    }

    @MainActor
    func testPrunesOldEntriesUnderCountAndBytePressure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RemoteBusinessCache(directory: directory)
        for i in 1...6 {
            await cache.put(scope: "snapshot-\(i)", payload: "snapshot", savedAt: Double(i))
            try await Task.sleep(for: .milliseconds(2))
        }
        let first = await cache.get(scope: "snapshot-1")
        let latest = await cache.get(scope: "snapshot-6")
        XCTAssertNil(first)
        XCTAssertEqual(latest, "snapshot")

        let payload = String(repeating: "A", count: RemoteBusinessCache.Kind.avatar.maxPayload)
        for i in 1...34 {
            await cache.put(scope: "avatar-\(i)", kind: .avatar, payload: payload, savedAt: Double(i))
        }
        let avatarDirectory = directory.appendingPathComponent("avatar")
        let files = try FileManager.default.contentsOfDirectory(at: avatarDirectory, includingPropertiesForKeys: [.fileSizeKey])
        let bytes = try files.reduce(0) { total, file in
            total + (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(bytes, RemoteBusinessCache.Kind.avatar.maxBytes)
        let lastAvatar = await cache.get(scope: "avatar-34", kind: .avatar)
        XCTAssertEqual(lastAvatar, payload)

        // 不能用编码后无法读取的快照覆盖已生效的正文。
        let oversizedOnDisk = String(repeating: "\u{0}", count: RemoteBusinessCache.Kind.avatar.maxPayload)
        await cache.put(scope: "avatar-34", kind: .avatar, payload: oversizedOnDisk, savedAt: 100)
        let unchanged = await cache.get(scope: "avatar-34", kind: .avatar)
        XCTAssertEqual(unchanged, payload)
    }

    @MainActor
    func testFailedWriteCanBeRetried() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory)
        let cache = RemoteBusinessCache(directory: directory)
        await cache.put(scope: "fixture", payload: "failed", savedAt: 50)
        let failed = await cache.get(scope: "fixture")
        XCTAssertNil(failed)
        try FileManager.default.removeItem(at: directory)
        await cache.put(scope: "fixture", payload: "retry", savedAt: 40)
        let retried = await cache.get(scope: "fixture")
        XCTAssertEqual(retried, "retry")
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
