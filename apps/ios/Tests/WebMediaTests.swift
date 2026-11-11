import XCTest
@testable import WeQRemote

final class WebMediaTests: XCTestCase {
    func testMediaRequestRejectsInvalidOrEmptyInputAndBoundsVideoWork() throws {
        XCTAssertNil(WebMediaRequest(message: ["id": "valid", "action": "start"]))
        XCTAssertNil(WebMediaRequest(message: ["id": "bad id", "audio": true]))
        let request = try XCTUnwrap(WebMediaRequest(message: ["id": "test-1", "audio": true,
            "video": ["width": 4000, "height": 3000, "fps": 60, "facingMode": "environment"]]))
        XCTAssertTrue(request.audio)
        XCTAssertEqual(request.video?.width, 640)
        XCTAssertEqual(request.video?.height, 480)
        XCTAssertEqual(request.video?.fps, 15)
        XCTAssertEqual(request.video?.front, false)
    }

    func testPCMFramesAreLittleEndianMonoAndKeepRemainderAcrossBuffers() {
        var encoder = WebMediaPCMEncoder()
        XCTAssertTrue(encoder.append([Float](repeating: 0.5, count: 300)).isEmpty)
        let packets = encoder.append([Float](repeating: 0.5, count: 341))
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0].count, 640)
        XCTAssertEqual(Array(packets[0].prefix(2)), [0, 64])
    }

    func testPCMClampsValuesAndNeverProducesOversizedPackets() {
        var encoder = WebMediaPCMEncoder()
        let packets = encoder.append([Float](repeating: -2, count: 16000))
        XCTAssertEqual(packets.count, 50)
        XCTAssertTrue(packets.allSatisfy { $0.count == 640 })
        XCTAssertEqual(Array(packets[0].prefix(2)), [0, 128])
        let finite = encoder.append([Float.nan, Float.infinity] + [Float](repeating: 0, count: 318))
        XCTAssertEqual(Array(finite[0].prefix(4)), [0, 0, 0, 0])
    }

    func testDialogCompletionOnlyRunsOnceIncludingCancelAfterSuccess() {
        var values: [String?] = []
        let completion = WebDialogCompletion<String?>(cancelled: nil) { values.append($0) }
        completion.finish("confirmed")
        completion.cancel()
        completion.finish("duplicate")
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first!, "confirmed")
        let cancelled = WebDialogCompletion<Bool>(cancelled: false) { XCTAssertFalse($0) }
        cancelled.cancel()
        cancelled.finish(true)
    }
}
