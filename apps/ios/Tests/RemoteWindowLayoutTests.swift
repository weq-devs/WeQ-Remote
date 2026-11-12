import XCTest
@testable import WeQRemote

final class RemoteWindowLayoutTests: XCTestCase {
    func testPhysicalCornerCoordinatesRoundTripWithoutLosingFractionalPoints() throws {
        let layout = RemoteWindowLayout(width: 1024, height: 768,
            topLeft: .init(width: 108.5, height: 32.25),
            topRight: .init(width: 12, height: 12))
        let decoded = try JSONDecoder().decode(RemoteWindowLayout.self, from: Data(layout.json.utf8))
        XCTAssertEqual(decoded, layout)
        XCTAssertTrue(layout.hasCornerOverlap)
        XCTAssertNotEqual(layout, RemoteWindowLayout(width: 1024, height: 768))
    }

    func testFullscreenAndOlderSystemsPublishZeroCorners() throws {
        let layout = RemoteWindowLayout(width: 1024, height: 768)
        XCTAssertFalse(layout.hasCornerOverlap)
        let decoded = try JSONDecoder().decode(RemoteWindowLayout.self, from: Data(layout.json.utf8))
        XCTAssertEqual(decoded.topLeft.width, 0)
        XCTAssertEqual(decoded.topLeft.height, 0)
        XCTAssertEqual(decoded.topRight.width, 0)
        XCTAssertEqual(decoded.topRight.height, 0)
    }
}
