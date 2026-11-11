import XCTest
@testable import WeQRemote

final class ConnectionHealthTests: XCTestCase {
    func testTransientFailureRecoveryAndBackground() {
        var health = ConnectionHealth()
        XCTAssertEqual(health.status, "待检查")
        health.failed()
        XCTAssertFalse(health.suspected)
        health.suspend()
        health.failed()
        XCTAssertFalse(health.suspected)
        health.failed()
        XCTAssertTrue(health.suspected)
        health.suspend()
        XCTAssertTrue(health.suspected)
        let date = Date(timeIntervalSince1970: 100)
        health.succeeded(at: date, latency: 42)
        XCTAssertEqual(health.status, "已连接")
        XCTAssertEqual(health.checkedAt, date)
        XCTAssertEqual(health.latency, 42)
        health.failed()
        XCTAssertFalse(health.suspected)
        XCTAssertEqual(health.checkedAt, date)
    }
}
