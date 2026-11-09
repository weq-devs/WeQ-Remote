import XCTest
import WebKit
@testable import WeQRemote

final class WebContainerTests: XCTestCase {
    @MainActor
    func testReloadKeepsWebViewAndDisconnectReturnsHomeWithoutResuming() async {
        let model = RemoteModel(network: EmbeddedNetwork())
        let remembered = model.rememberedComputer
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        model.adoptWebSession(session)
        session.onReady?()
        XCTAssertTrue(model.webReady)
        session.onLoading?()
        XCTAssertFalse(model.webReady)
        XCTAssertTrue(model.webSession === session)
        session.onReady?()
        model.disconnect()
        XCTAssertFalse(model.webReady)
        XCTAssertNil(model.webSession)
        XCTAssertEqual(model.rememberedComputer, remembered)
        await model.reconnect()
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.webSession)
    }
    @MainActor
    func testShellMenuUsesInjectedBridgeAndWebOwnsBackGesture() {
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        defer { session.close() }
        XCTAssertFalse(session.view.allowsBackForwardNavigationGestures)
        let script = session.view.configuration.userContentController.userScripts.first { $0.source.contains("weqRemoteShell") }
        XCTAssertEqual(script?.injectionTime, .atDocumentStart)
        XCTAssertEqual(script?.isForMainFrameOnly, true)
        session.onLoading = {}
        session.onDisconnect = {}
        session.close()
        XCTAssertNil(session.onLoading)
        XCTAssertNil(session.onDisconnect)
    }
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
        XCTAssertTrue(session.view.uiDelegate === session)
        XCTAssertEqual(session.view.configuration.mediaTypesRequiringUserActionForPlayback, .all)
    }
}
