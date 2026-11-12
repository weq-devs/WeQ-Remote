import XCTest
@testable import WeQRemote

final class ConnectionHealthTests: XCTestCase {
    func testMissingNetworkDebouncesAndRecoveryNeedsAnActualResponse() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.networkChanged(available: false, now: 1)
        health.evaluate(now: 2.9)
        XCTAssertNil(health.warning)
        health.evaluate(now: 3)
        XCTAssertEqual(health.warning?.message, "网络已断开，恢复后自动重连")
        health.networkChanged(available: true, now: 4)
        XCTAssertEqual(health.warning?.message, "连接已中断，正在重连…")
        let date = Date(timeIntervalSince1970: 100)
        health.succeeded(at: date, latency: 42, now: 5)
        XCTAssertNil(health.warning)
        XCTAssertEqual(health.status, "已连接")
        XCTAssertEqual(health.checkedAt, date)
        XCTAssertEqual(health.latency, 42)
    }

    func testShortNetworkSwitchDoesNotFlashAWarning() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.networkChanged(available: false, now: 1)
        health.networkChanged(available: true, now: 2)
        health.evaluate(now: 3)
        XCTAssertNil(health.warning)
    }

    func testFirstFailureStartsDeadlineBeforeRouteRecoveryCompletes() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        XCTAssertEqual(health.nextDeadline, 30)
        health.failed(now: 5)
        XCTAssertEqual(health.nextDeadline, 8)
        health.failed(now: 7) // 重试失败不能不断推迟提醒。
        health.evaluate(now: 7.9)
        XCTAssertNil(health.warning)
        health.evaluate(now: 8)
        XCTAssertEqual(health.warning, .connection)
        XCTAssertNil(health.nextDeadline)
    }

    func testSuccessfulRecoveryDuringDebounceDoesNotFlashAWarning() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.failed(now: 5)
        health.succeeded(at: Date(), latency: 10, now: 7)
        health.evaluate(now: 8)
        XCTAssertNil(health.warning)
    }

    func testHungRequestCannotBlockTheThirtySecondDeadline() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.evaluate(now: 29.9)
        XCTAssertNil(health.warning)
        health.evaluate(now: 30)
        XCTAssertEqual(health.warning, .connection)
        health.evaluate(now: 180)
        XCTAssertEqual(health.warning, .connection)
    }

    func testBackgroundTimeDoesNotCountAndExistingWarningSurvivesResume() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.failed(now: 1)
        health.suspend()
        health.evaluate(now: 100)
        XCTAssertNil(health.warning)
        health.resume(now: 100)
        health.evaluate(now: 129)
        XCTAssertNil(health.warning)
        health.evaluate(now: 130)
        XCTAssertEqual(health.warning, .connection)
        health.suspend()
        health.resume(now: 500)
        XCTAssertEqual(health.warning, .connection)
    }

    func testNetworkLossTakesPriorityAndDuplicateEventsDoNotDelayIt() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.failed(now: 1)
        health.networkChanged(available: false, now: 2)
        health.networkChanged(available: false, now: 3)
        health.evaluate(now: 4)
        XCTAssertEqual(health.warning, .network)
        health.evaluate(now: 40)
        XCTAssertEqual(health.warning, .network)
    }
}
