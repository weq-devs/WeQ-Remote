import XCTest
import CryptoKit
import WebKit
@testable import WeQRemote

final class WebDataStoreTests: XCTestCase {

    private func request(_ time: Double, _ revision: String, base: String? = nil,
                         keys: [String], updates: [(String, String)]) -> BusinessCacheRecordWrite {
        BusinessCacheRecordWrite(savedAt: time, revision: revision, base: base, keys: keys,
                                 records: updates.map { BusinessCacheRecord(key: $0.0, payload: $0.1) })
    }

    private func recordsFolder(_ directory: URL, scope: String, kind: String) -> URL {
        let hash = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(kind)/\(hash).records")
    }

    @MainActor
    func testIncrementalRecordsRetainUnchangedFileAndSupportLegacyWriters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = "account-a"
        let folder = recordsFolder(directory, scope: scope, kind: "business")
        let large = String(repeating: "好友", count: 100_000)
        do {
            let cache = RemoteBusinessCache(directory: directory)
            await cache.put(scope: scope, payload: "old web", savedAt: 10)
            guard case .legacy(let original) = await cache.getRecords(scope: scope, kind: .business, newerThan: 0) else {
                return XCTFail("Expected legacy snapshot")
            }
            XCTAssertEqual(original, "old web")
            let created = await cache.putRecords(scope: scope, kind: .business, request:
                request(11, "initial", keys: ["directory", "preview"], updates: [("directory", large), ("preview", "before")]))
            XCTAssertEqual(created, .stored)
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            let untouched = try XCTUnwrap(urls.first { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) == large.utf8.count })
            let inode = try FileManager.default.attributesOfItem(atPath: untouched.path)[.systemFileNumber] as? NSNumber

            let changed = await cache.putRecords(scope: scope, kind: .business, request:
                request(12, "next", base: "initial", keys: ["preview", "directory"], updates: [("preview", "after")]))
            XCTAssertEqual(changed, .stored)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: untouched.path)[.systemFileNumber] as? NSNumber, inode)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 3)
        }

        let reopened = RemoteBusinessCache(directory: directory)
        guard case .records(let savedAt, let records) = await reopened.getRecords(scope: scope, kind: .business, newerThan: 11) else {
            return XCTFail("Expected record snapshot")
        }
        XCTAssertEqual(savedAt, 12)
        XCTAssertEqual(records.map(\.key), ["preview", "directory"])
        XCTAssertTrue(records.map(\.payload) == ["after", large])
        let current = await reopened.getRecords(scope: scope, kind: .business, newerThan: 12)
        XCTAssertNil(current)
        let stale = await reopened.putRecords(scope: scope, kind: .business, request:
            request(13, "stale", base: "initial", keys: ["preview"], updates: [("preview", "stale")]))
        XCTAssertEqual(stale, .needsFull)
        await reopened.put(scope: scope, payload: "stale old writer", savedAt: 11)
        let legacy = await reopened.get(scope: scope)
        XCTAssertEqual(legacy, "old web")
        await reopened.put(scope: scope, payload: "fresh old writer", savedAt: 14)
        guard case .legacy(let replacement) = await reopened.getRecords(scope: scope, kind: .business, newerThan: 12) else {
            return XCTFail("Expected newer legacy snapshot")
        }
        XCTAssertEqual(replacement, "fresh old writer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testRecordLimitsMissingFilesAndRevocation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RemoteBusinessCache(directory: directory)
        let scope = "fixture"
        let initial = await cache.putRecords(scope: scope, kind: .messages, request:
            request(20, "start", keys: ["one", "two"], updates: [("one", "old-one"), ("two", "old-two")]))
        XCTAssertEqual(initial, .stored)
        let tooLarge = String(repeating: "X", count: RemoteBusinessCache.Kind.messages.maxPayload)
        let rejected = await cache.putRecords(scope: scope, kind: .messages, request:
            request(21, "over-limit", base: "start", keys: ["one", "two"], updates: [("one", tooLarge)]))
        XCTAssertEqual(rejected, .unavailable)
        guard case .records(let savedAt, let values) = await cache.getRecords(scope: scope, kind: .messages, newerThan: 19) else {
            return XCTFail("Lost prior snapshot")
        }
        XCTAssertEqual(savedAt, 20)
        XCTAssertEqual(values.map(\.payload), ["old-one", "old-two"])
        let otherScope = await cache.getRecords(scope: "unrelated", kind: .messages, newerThan: 0)
        XCTAssertNil(otherScope)

        let folder = recordsFolder(directory, scope: scope, kind: "messages")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let lost = try XCTUnwrap(files.first { (try? String(contentsOf: $0, encoding: .utf8)) == "old-two" })
        try FileManager.default.removeItem(at: lost)
        let partial = await cache.putRecords(scope: scope, kind: .messages, request:
            request(22, "partial", base: "start", keys: ["one", "two"], updates: [("one", "new-one")]))
        XCTAssertEqual(partial, .needsFull)
        let recovered = await cache.putRecords(scope: scope, kind: .messages, request:
            request(22, "partial", keys: ["one", "two"], updates: [("one", "new-one"), ("two", "recovered")]))
        XCTAssertEqual(recovered, .stored)
        await cache.put(scope: scope, kind: .avatar, payload: "avatar", savedAt: 23)
        cache.clear()
        let oldWriter = await cache.putRecords(scope: scope, kind: .messages, request:
            request(24, "late", keys: ["one"], updates: [("one", "late")]))
        XCTAssertEqual(oldWriter, .unavailable)
        let fresh = RemoteBusinessCache(directory: directory)
        let purged = await fresh.getRecords(scope: scope, kind: .messages, newerThan: 0)
        let avatar = await fresh.get(scope: scope, kind: .avatar)
        XCTAssertNil(purged)
        XCTAssertNil(avatar)
        let newWriter = await fresh.putRecords(scope: scope, kind: .messages, request:
            request(25, "fresh", keys: ["one"], updates: [("one", "fresh")]))
        XCTAssertEqual(newWriter, .stored)
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
        let existing = await cache.putRecords(scope: "snapshot-6", kind: .business, request:
            request(7, "existing", keys: ["query"], updates: [("query", "record")]))
        let newScope = await cache.putRecords(scope: "snapshot-7", kind: .business, request:
            request(8, "new", keys: ["query"], updates: [("query", "record")]))
        let evicted = await cache.getRecords(scope: "snapshot-3", kind: .business, newerThan: 0)
        let retained = await cache.getRecords(scope: "snapshot-4", kind: .business, newerThan: 0)
        XCTAssertEqual(existing, .stored)
        XCTAssertEqual(newScope, .stored)
        XCTAssertNil(evicted)
        XCTAssertNotNil(retained)

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
