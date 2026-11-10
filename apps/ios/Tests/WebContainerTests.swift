import XCTest
import WebKit
@testable import WeQRemote

final class WebContainerTests: XCTestCase {
    @MainActor
    func testWebKeyboardDoesNotAddAFormNavigationToolbar() {
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        defer { session.close() }
        XCTAssertTrue(session.view is RemoteWebView)
        XCTAssertNil(session.view.inputAccessoryView)
        XCTAssertEqual(session.view.scrollView.contentInsetAdjustmentBehavior, .never)
    }
    @MainActor
    func testStartupProgressStaysHomeUntilTheSurfaceIsReady() {
        let model = RemoteModel(network: EmbeddedNetwork())
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        model.adoptWebSession(session)
        session.receiveStartup("loading", message: "正在绘制 WeQ 界面")
        XCTAssertFalse(model.webReady)
        XCTAssertEqual(model.webLoadingStage, "正在绘制 WeQ 界面")
        session.receiveStartup("ready", message: nil)
        XCTAssertTrue(model.webReady)
        model.disconnect()
        XCTAssertNil(session.onProgress)
    }
    @MainActor
    func testHTMLFinishDoesNotEnterUntilBusinessIsReady() {
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        defer { session.close() }
        var ready = 0
        session.onReady = { ready += 1 }
        session.webView(session.view, didFinish: nil)
        session.receiveStartup("loading", message: nil)
        XCTAssertEqual(ready, 0)
        session.receiveStartup("ready", message: nil)
        session.receiveStartup("ready", message: nil)
        XCTAssertEqual(ready, 1)
    }
    @MainActor
    func testStartupErrorsStayHomeAndRestoreActionsCanBeShown() {
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        defer { session.close() }
        var ready = false
        var failure: Error?
        session.onReady = { ready = true }
        session.onFailure = { failure = $0 }
        session.receiveStartup("error", message: "合成恢复超时")
        XCTAssertFalse(ready)
        XCTAssertEqual(failure?.localizedDescription, "合成恢复超时")
        session.webView(session.view, didStartProvisionalNavigation: nil)
        session.receiveStartup("action-required", message: nil)
        XCTAssertTrue(ready)
    }
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
