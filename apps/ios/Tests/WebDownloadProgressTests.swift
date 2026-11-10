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
        XCTAssertNil(WebDownloadProgress(completed: 3, total: 2, loadedBytes: 1, totalBytes: 2))
        XCTAssertNil(WebDownloadProgress(completed: 2, total: 2, loadedBytes: 1, totalBytes: 2))
        XCTAssertNil(WebDownloadProgress(completed: 1, total: 2, loadedBytes: 2, totalBytes: 2))
        XCTAssertNil(WebDownloadProgress(completed: 0, total: 0, loadedBytes: 0, totalBytes: 0))
        XCTAssertNil(WebDownloadProgress(completed: 1, total: 2, loadedBytes: -1, totalBytes: 2))
        XCTAssertNil(WebDownloadProgress(completed: 1, total: 2, loadedBytes: 1, totalBytes: Int64.max))
        XCTAssertFalse(try XCTUnwrap(WebDownloadProgress(completed: 2, total: 2, loadedBytes: 2, totalBytes: 2)).downloading)
    }
}
