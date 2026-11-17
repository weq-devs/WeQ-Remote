import XCTest
@testable import WeQRemote

final class WebResourceProgressTests: XCTestCase {
    func testBridgeRejectsMissingFractionalBooleanAndUnboundedCounts() {
        XCTAssertNil(WebResourceProgress(message: ["completed": 1]))
        for invalid: Any in [0.5, -1, 4097, Double.infinity, Double.nan, true, "1"] {
            XCTAssertNil(WebResourceProgress(message: ["completed": invalid, "total": 2]))
            XCTAssertNil(WebResourceProgress(message: ["completed": 0, "total": invalid]))
        }
        XCTAssertNotNil(WebResourceProgress(message: ["completed": 1, "total": 2]))
        // 旧桥附带的字节数不是下载量，也不再参与就绪判断。
        XCTAssertEqual(WebResourceProgress(message: ["completed": 1, "total": 2, "loadedBytes": 0, "totalBytes": 10000]),
                       WebResourceProgress(completed: 1, total: 2))
    }

    func testResourceReadinessNeverClaimsBytesOrOverallPercentage() throws {
        let value = try XCTUnwrap(WebResourceProgress(completed: 1, total: 2))
        XCTAssertEqual(value.detail, "网页资源已就绪 1 / 2 项")
        XCTAssertEqual(value.stage, WebResourceProgress.preparingMessage)
        let complete = try XCTUnwrap(WebResourceProgress(completed: 2, total: 2))
        XCTAssertEqual(complete.detail, "网页资源已就绪 2 / 2 项")
        XCTAssertEqual(complete.stage, "正在初始化网页")
        XCTAssertNotNil(WebResourceProgress(completed: 0, total: 4096))
        for (completed, total) in [(3, 2), (-1, 2), (0, 0), (0, 4097)] {
            XCTAssertNil(WebResourceProgress(completed: completed, total: total))
        }
    }
}
