import XCTest
import WebKit
import Combine
@testable import WeQRemote

final class WebContainerTests: XCTestCase {
    @MainActor
    func testWindowGeometryBridgeStartsWithTheMainDocument() {
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        defer { session.close() }
        let script = session.view.configuration.userContentController.userScripts.first {
            $0.source == RemoteWebSession.windowLayoutScript
        }
        XCTAssertEqual(script?.injectionTime, .atDocumentStart)
        XCTAssertEqual(script?.isForMainFrameOnly, true)
        let view = session.view
        session.updateWindowLayout(.init(width: 1024, height: 768,
            topLeft: .init(width: 100, height: 32)))
        session.updateWindowLayout(.init(width: 1024, height: 768))
        XCTAssertTrue(session.view === view)
        XCTAssertEqual(view.scrollView.contentInsetAdjustmentBehavior, .never)
    }
    @MainActor
    func testConnectionWarningDoesNotWaitForAnotherCheckOrReplaceThePage() async throws {
        let model = RemoteModel(network: EmbeddedNetwork())
        model.disconnect() // 不读取保存的电脑或发起真实重连。
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        model.adoptWebSession(session)
        session.receiveStartup("ready", message: nil)
        let paths = AsyncStream<Bool>.makeStream()
        let started = expectation(description: "前台连接监听已启动")
        let observer = model.$health.dropFirst().first().sink { _ in started.fulfill() }
        let monitoring = Task { await model.monitorConnectionHealth(paths: paths.stream) }
        defer { observer.cancel(); monitoring.cancel(); paths.continuation.finish(); model.disconnect() }
        await fulfillment(of: [started], timeout: 2)
        session.onConnectionFailure?()
        try await Task.sleep(for: .milliseconds(10300))
        XCTAssertEqual(model.health.warning, .connection)
        XCTAssertTrue(model.webReady)
        XCTAssertTrue(model.webSession === session)
        monitoring.cancel()
        await monitoring.value
        XCTAssertEqual(model.health.warning, .connection)
        model.disconnect()
        XCTAssertNil(session.onConnectionFailure)
        XCTAssertNil(model.health.warning)
    }

    @MainActor
    func testConnectionFailureBridgeIsInstalledBeforeBusinessRequests() {
        XCTAssertFalse(RemoteWebSession.connectionHealthScript.isEmpty)
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        defer { session.close() }
        let script = session.view.configuration.userContentController.userScripts.first {
            $0.source == RemoteWebSession.connectionHealthScript
        }
        XCTAssertEqual(script?.injectionTime, .atDocumentStart)
        XCTAssertEqual(script?.isForMainFrameOnly, true)
    }

    @MainActor
    func testDownloadProgressResetsOnReloadAndDoesNotReplaceStartupStage() throws {
        let model = RemoteModel(network: EmbeddedNetwork())
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(), endpoint: URL(string: "https://192.168.1.8:7691")!)
        model.adoptWebSession(session)
        let partial = try XCTUnwrap(WebDownloadProgress(completed: 1, total: 2, loadedBytes: 1000, totalBytes: 10000))
        session.receiveDownload(partial)
        XCTAssertEqual(model.webDownload, partial)
        XCTAssertFalse(model.webReady)
        session.webView(session.view, didCommit: nil)
        XCTAssertEqual(model.webLoadingStage, "正在下载网页资源")
        session.receiveStartup("loading", message: "正在检查恢复状态")
        session.receiveDownload(try XCTUnwrap(WebDownloadProgress(completed: 2, total: 2, loadedBytes: 10000, totalBytes: 10000)))
        XCTAssertEqual(model.webLoadingStage, "正在检查恢复状态")
        session.webView(session.view, didStartProvisionalNavigation: nil)
        XCTAssertNil(model.webDownload)
        session.receiveDownload(partial)
        session.receiveStartup("ready", message: nil)
        XCTAssertNil(model.webDownload)
        session.receiveDownload(partial)
        XCTAssertNil(model.webDownload)
        model.disconnect()
        XCTAssertNil(session.onDownload)
    }
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
        session.onMenu = {}
        session.close()
        XCTAssertNil(session.onLoading)
        XCTAssertNil(session.onMenu)
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
    @MainActor
    func testNativeMediaBridgeIsOnlyInjectedForTheHttpCaptureFallback() {
        for scheme in ["http", "https"] {
            let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                           endpoint: URL(string: "\(scheme)://192.168.1.8:7691")!)
            let script = session.view.configuration.userContentController.userScripts.first { $0.source.contains("window.weqRemoteMedia=") }
            XCTAssertEqual(script != nil, scheme == "http")
            if let script {
                XCTAssertEqual(script.injectionTime, .atDocumentStart)
                XCTAssertTrue(script.isForMainFrameOnly)
            }
            session.close()
        }
    }
    @MainActor
    func testExternalWindowBridgeIsInjectedBeforeBusinessScriptsAndOnlyForTheMainFrame() {
        let session = RemoteWebSession(configuration: WKWebViewConfiguration(),
                                       endpoint: URL(string: "https://192.168.1.8:7691")!)
        defer { session.close() }
        let script = session.view.configuration.userContentController.userScripts.first {
            $0.source == RemoteWebSession.externalLinksScript
        }
        XCTAssertNotNil(script)
        XCTAssertEqual(script?.injectionTime, .atDocumentStart)
        XCTAssertEqual(script?.isForMainFrameOnly, true)
    }
}
