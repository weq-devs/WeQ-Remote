import XCTest
import WebKit
@testable import WeQRemote

final class WebDataStoreTests: XCTestCase {
    @MainActor
    func testReconnectReusesOnlyTheSameComputerAndAuthorization() {
        let cache = RemoteWebDataStore()
        let endpoint = URL(string: "https://192.168.1.8:7691")!
        let token = String(repeating: "a", count: 64)
        let pin = String(repeating: "f", count: 64)
        let first = cache.dataStore(endpoint: endpoint, token: token, fingerprint: pin)
        XCTAssertFalse(first.isPersistent)
        XCTAssertTrue(first === cache.dataStore(endpoint: endpoint, token: token, fingerprint: pin))
        let next = cache.dataStore(endpoint: endpoint, token: String(repeating: "b", count: 64), fingerprint: pin)
        XCTAssertFalse(first === next)
        let changedPin = cache.dataStore(endpoint: endpoint, token: String(repeating: "b", count: 64), fingerprint: nil)
        XCTAssertFalse(next === changedPin)
        let changedComputer = cache.dataStore(endpoint: URL(string: "https://192.168.1.9:7691")!, token: token, fingerprint: pin)
        XCTAssertFalse(changedPin === changedComputer)
        cache.clear()
        XCTAssertFalse(changedComputer === cache.dataStore(endpoint: URL(string: "https://192.168.1.9:7691")!, token: token, fingerprint: pin))
    }
}
