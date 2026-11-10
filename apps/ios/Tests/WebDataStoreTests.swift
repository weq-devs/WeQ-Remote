import XCTest
import WebKit
@testable import WeQRemote

final class WebDataStoreTests: XCTestCase {
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
