import XCTest
@testable import WeQRemote

final class WebDownloadProgressTests: XCTestCase {
    func testBridgeRejectsMissingFractionalAndUnboundedNumbers() {
        XCTAssertNil(WebDownloadProgress(message: ["completed": 1]))
        XCTAssertNil(WebDownloadProgress(message: ["completed": 0.5, "total": 2, "loadedBytes": 1, "totalBytes": 2]))
        XCTAssertNil(WebDownloadProgress(message: ["completed": 1, "total": 2, "loadedBytes": 1, "totalBytes": Double.infinity]))
        XCTAssertNotNil(WebDownloadProgress(message: ["completed": 1, "total": 2, "loadedBytes": 1, "totalBytes": 2]))
    }
    func testProgressUsesBytesRatherThanResourceCount() throws {
        let value = try XCTUnwrap(WebDownloadProgress(completed: 1, total: 2, loadedBytes: 1000, totalBytes: 10000))
        XCTAssertEqual(value.fraction, 0.1, accuracy: 0.0001)
        XCTAssertTrue(value.downloading)
        XCTAssertTrue(value.detail.contains("1 / 2"))
        XCTAssertTrue(value.detail.contains("来源待确认"))
        XCTAssertNil(value.downloadedBytes)
        XCTAssertNil(WebDownloadProgress(completed: 3, total: 2, loadedBytes: 1, totalBytes: 2))
        XCTAssertNil(WebDownloadProgress(completed: 2, total: 2, loadedBytes: 1, totalBytes: 2))
        XCTAssertNil(WebDownloadProgress(completed: 1, total: 2, loadedBytes: 2, totalBytes: 2))
        XCTAssertNil(WebDownloadProgress(completed: 0, total: 0, loadedBytes: 0, totalBytes: 0))
        XCTAssertNil(WebDownloadProgress(completed: 1, total: 2, loadedBytes: -1, totalBytes: 2))
        XCTAssertNil(WebDownloadProgress(completed: 1, total: 2, loadedBytes: 1, totalBytes: Int64.max))
        XCTAssertFalse(try XCTUnwrap(WebDownloadProgress(completed: 2, total: 2, loadedBytes: 2, totalBytes: 2)).downloading)
    }

    func testRealDownloadAndCacheStaySeparateFromResourceWeight() throws {
        let value = try XCTUnwrap(WebDownloadProgress(message: ["completed": 2, "total": 2, "loadedBytes": 10000,
            "totalBytes": 10000, "downloadedBytes": 800, "cachedBytes": 9000, "unknownBytes": 0]))
        XCTAssertEqual(value.fraction, 1)
        XCTAssertEqual(value.downloadedBytes, 800) // 采用实际响应体，不拿清单中的 1000 充当下载量。
        XCTAssertEqual(value.cachedBytes, 9000)
        XCTAssertTrue(value.detail.contains("已确认下载"))
        XCTAssertTrue(value.detail.contains("缓存复用"))
        XCTAssertFalse(value.detail.contains("来源待确认"))
        XCTAssertEqual(value.stage, "正在初始化网页")
        let cached = try XCTUnwrap(WebDownloadProgress(completed: 2, total: 2, loadedBytes: 10000, totalBytes: 10000,
            downloadedBytes: 0, cachedBytes: 10000, unknownBytes: 0))
        XCTAssertTrue(cached.fullyCached)
        XCTAssertEqual(cached.detail, "已复用网页缓存")
        XCTAssertFalse(value.fullyCached)
        for invalid: Any in [-1, 0.5, true, Double.infinity] {
            XCTAssertNil(WebDownloadProgress(message: ["completed": 1, "total": 2, "loadedBytes": 1,
                "totalBytes": 2, "downloadedBytes": invalid, "cachedBytes": 0, "unknownBytes": 1]))
        }
        XCTAssertNil(WebDownloadProgress(message: ["completed": 1, "total": 2, "loadedBytes": 1, "totalBytes": 2, "downloadedBytes": 0]))
        XCTAssertNil(WebDownloadProgress(completed: 1, total: 2, loadedBytes: 1, totalBytes: 2,
            downloadedBytes: 0, cachedBytes: 1, unknownBytes: 1))
    }
}
