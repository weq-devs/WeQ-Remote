import XCTest
import WebKit
@testable import WeQRemote

final class WebContainerTests: XCTestCase {
    @MainActor
    func testBackgroundVideoStaysInlineWithoutChangingPlaybackPolicy() {
        let configuration = WKWebViewConfiguration()
        // 显式模拟 iPhone 默认值，避免 iPad 默认允许页内播放掩盖回归。
        configuration.allowsInlineMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let session = RemoteWebSession(configuration: configuration,
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        defer { session.close() }

        XCTAssertTrue(session.view.configuration.allowsInlineMediaPlayback)
        XCTAssertEqual(session.view.configuration.mediaTypesRequiringUserActionForPlayback, .all)
    }
}
