import XCTest
@testable import WeQRemote

final class ConnectionHealthTests: XCTestCase {
    func testProgressiveBudgetsAndWarningDuringSecondAttempt() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        XCTAssertEqual(health.requestTimeout, 5)
        health.beginCheck(now: 0)
        health.checkFailed(now: 5)
        XCTAssertNil(health.warning)
        XCTAssertEqual(health.requestTimeout, 10)
        health.beginCheck(now: 5)
        XCTAssertEqual(health.nextDeadline, 10)
        health.evaluate(now: 9.99)
        XCTAssertNil(health.warning)
        health.evaluate(now: 10)
        XCTAssertEqual(health.warning, .connection)
        // 提醒不等于请求失败，第二轮仍有剩余 5 秒。
        XCTAssertEqual(health.failedChecks, 1)
        health.checkFailed(now: 15)
        XCTAssertEqual(health.requestTimeout, 15)
        health.beginCheck(now: 15)
        health.checkFailed(now: 30)
        XCTAssertEqual(health.requestTimeout, 20)
        health.succeeded(at: Date(), latency: 42, now: 31)
        XCTAssertNil(health.warning)
        XCTAssertEqual(health.requestTimeout, 5)
        XCTAssertEqual(health.checkInterval, 15)
    }

    func testMissingNetworkAndActualRecovery() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.networkChanged(available: false, now: 1)
        health.networkChanged(available: false, now: 3)
        health.evaluate(now: 10.99)
        XCTAssertNil(health.warning)
        health.evaluate(now: 11)
        XCTAssertEqual(health.warning, .network)
        health.networkChanged(available: true, now: 12)
        XCTAssertEqual(health.warning, .connection)
        health.succeeded(at: Date(), latency: 42, now: 13)
        XCTAssertNil(health.warning)
    }

    func testShortSwitchAndSuccessfulSecondAttemptDoNotFlash() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.networkChanged(available: false, now: 1)
        health.networkChanged(available: true, now: 2)
        health.checkFailed(now: 5)
        health.beginCheck(now: 5)
        health.succeeded(at: Date(), latency: 10, now: 9)
        health.evaluate(now: 10)
        XCTAssertNil(health.warning)
    }

    func testWebFailuresAndStaleChecksCannotDelayWarning() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.failed(now: 1)
        health.failed(now: 8)
        health.evaluate(now: 11)
        XCTAssertEqual(health.warning, .connection)
        health.succeeded(at: Date(), latency: 10, now: 12)
        health.evaluate(now: 41.99)
        XCTAssertNil(health.warning)
        health.evaluate(now: 42)
        XCTAssertEqual(health.warning, .connection)
    }

    func testBackgroundTimeDoesNotCountAndWarningSurvivesResume() {
        var health = ConnectionHealth()
        health.resume(now: 0)
        health.checkFailed(now: 1)
        health.beginCheck(now: 2)
        health.suspend()
        health.evaluate(now: 100)
        XCTAssertNil(health.warning)
        health.resume(now: 100)
        XCTAssertEqual(health.requestTimeout, 5)
        health.evaluate(now: 130)
        XCTAssertEqual(health.warning, .connection)
        health.suspend()
        health.resume(now: 500)
        XCTAssertEqual(health.warning, .connection)
    }

    @MainActor
    func testTimeoutCancelsWholeRoundButNotCaller() async throws {
        let start = ContinuousClock.now
        do {
            let _: Int = try await withRemoteTimeout(0.03) {
                try await Task.sleep(for: .seconds(5))
                return 1
            }
            XCTFail("应在整轮预算用尽后超时")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertLessThan(elapsedMillis(ContinuousClock.now - start), 1000)
        XCTAssertFalse(Task.isCancelled)
        let result = try await withRemoteTimeout(1) { 42 }
        XCTAssertEqual(result, 42)
    }
}
