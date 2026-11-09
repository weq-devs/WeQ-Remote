import SwiftUI
import WebKit

private final class RemoteCaptureHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteWebSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let owner, let id = message.body as? String,
              id.count <= 64, let url = message.frameInfo.request.url,
              RemoteWebPolicy.sameOrigin(url, endpoint: owner.endpoint) else { return }
        owner.capture(id)
    }
}

private final class RemoteShellHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteWebSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let owner, message.body as? String == "menu",
              let url = message.frameInfo.request.url,
              RemoteWebPolicy.sameOrigin(url, endpoint: owner.endpoint) else { return }
        owner.openMenu()
    }
}

private final class RemoteStartupHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteWebSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let owner, let url = message.frameInfo.request.url,
              RemoteWebPolicy.sameOrigin(url, endpoint: owner.endpoint),
              let value = message.body as? [String: String], let state = value["state"] else { return }
        owner.receiveStartup(state, message: value["message"])
    }
}

@MainActor
final class RemoteWebSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let view: WKWebView
    let endpoint: URL
    private let fingerprint: String?
    private var downloads: [ObjectIdentifier: (WKDownload, URL)] = [:]
    private var closed = false
    private var startupTimeout: Task<Void, Never>?
    private var startupFinished = false
    // 正式页面准备完成才切到全屏；HTML 加载完成仍留在首页。
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onLoading: (() -> Void)?
    var onProgress: ((String) -> Void)?
    var onDisconnect: (() -> Void)?

    init(configuration: WKWebViewConfiguration, endpoint: URL, fingerprint: String? = nil) {
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        // 网页背景已有 playsinline；iPhone 还需在创建 WebView 前允许页内播放。
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = "WeQRemote"
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let capture = RemoteCaptureHandler()
        capture.owner = self
        configuration.userContentController.add(capture, name: "weqCapture")
        let shell = RemoteShellHandler()
        shell.owner = self
        configuration.userContentController.add(shell, name: "weqShell")
        let startup = RemoteStartupHandler()
        startup.owner = self
        configuration.userContentController.add(startup, name: "weqStartup")
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.addEventListener('weq-remote-startup',function(){if(window.weqRemoteStartup)window.webkit.messageHandlers.weqStartup.postMessage(window.weqRemoteStartup)});",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.weqRemoteShell={openMenu:function(){window.webkit.messageHandlers.weqShell.postMessage('menu')}};",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.isInspectable = false
        // 全屏网页由页面自己的 env(safe-area-inset-*) 处理系统区域，WebView 不再额外内缩。
        view.scrollView.contentInsetAdjustmentBehavior = .never
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !closed else { return }
        webView.evaluateJavaScript("if(window.weqRemoteStartup)window.webkit.messageHandlers.weqStartup.postMessage(window.weqRemoteStartup)", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !closed, !startupFinished else { return }
        onProgress?("正在初始化 WeQ 页面")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        startupFinished = false
        onLoading?()
        onProgress?("正在下载网页资源")
        startupTimeout?.cancel()
        startupTimeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            self?.receiveStartup("error", message: "WeQ 页面准备超时，请重试并确认电脑已更新到支持页面就绪通知的版本。")
        }
    }

    func receiveStartup(_ state: String, message: String?) {
        guard !closed, !startupFinished else { return }
        if state == "loading" {
            onProgress?(String((message ?? "正在初始化 WeQ 页面").prefix(100)))
        } else if state == "ready" || state == "action-required" {
            startupFinished = true
            startupTimeout?.cancel()
            onReady?()
        } else if state == "error" {
            startupFinished = true
            startupTimeout?.cancel()
            onFailure?(NSError(domain: "WeQRemoteStartup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String((message ?? "WeQ 页面启动失败，请重试。").prefix(500))]))
        }
    }

    fileprivate func openMenu() {
        guard !closed, var presenter = view.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !(presenter is UIAlertController) else { return }
        let menu = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "重新加载", style: .default) { [weak self] _ in
            guard let self, !self.closed else { return }
            self.onLoading?()
            self.view.reload()
        })
        menu.addAction(UIAlertAction(title: "断开连接", style: .default) { [weak self] _ in self?.onDisconnect?() })
        menu.addAction(UIAlertAction(title: "取消", style: .cancel))
        menu.popoverPresentationController?.sourceView = view
        menu.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.maxX - 24, y: view.safeAreaInsets.top + 24, width: 1, height: 1)
        presenter.present(menu, animated: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !closed else { return }
        onFailure?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !closed else { return }
        onFailure?(error)
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard fingerprint != nil else { completionHandler(.performDefaultHandling, nil); return }
        if let credential = pinnedCredential(challenge, endpoint: endpoint, fingerprint: fingerprint) { completionHandler(.useCredential, credential) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if RemoteWebPolicy.resource(url, endpoint: endpoint) {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            openExternal(url)
        }
    }

    private func sameOrigin(_ url: URL) -> Bool {
        RemoteWebPolicy.sameOrigin(url, endpoint: endpoint)
    }

    private func openExternal(_ url: URL) {
        guard RemoteWebPolicy.external(url) else { return }
        UIApplication.shared.open(url)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard !closed, let url = navigationAction.request.url else { return nil }
        if sameOrigin(url) { webView.load(navigationAction.request) }
        else { openExternal(url) }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let allowed = !closed && origin.protocol == endpoint.scheme && origin.host == endpoint.host
            && (origin.port == 0 ? (origin.protocol == "https" ? 443 : 80) : origin.port) == (endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80))
        decisionHandler(allowed ? .prompt : .deny)
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
            decisionHandler(.cancel)
            onFailure?(RemoteError.http(http.statusCode))
            return
        }
        let attachment = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().hasPrefix("attachment") == true
        decisionHandler(!closed && (attachment || !response.canShowMIMEType) ? .download : closed ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard !closed else { completionHandler(.cancelAuthenticationChallenge, nil); return }
        if fingerprint == nil { completionHandler(.performDefaultHandling, nil) }
        else if let credential = pinnedCredential(challenge, endpoint: endpoint, fingerprint: fingerprint) { completionHandler(.useCredential, credential) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(!closed && request.url.map(sameOrigin) == true ? .allow : .cancel)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard !closed else { completionHandler(nil); return }
        do {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("weq-download-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let name = (suggestedFilename as NSString).lastPathComponent
            let target = directory.appendingPathComponent(name.isEmpty || name == "." || name == ".." ? "download" : name)
            downloads[ObjectIdentifier(download)] = (download, target)
            completionHandler(target)
        } catch { completionHandler(nil); showDownloadError() }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let (_, file) = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        shareFile(file)
    }

    private func shareFile(_ file: URL) {
        guard !closed, var presenter = view.window?.rootViewController else { removeDownload(file); return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        share.popoverPresentationController?.sourceView = view
        share.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        presenter.present(share, animated: true)
    }

    fileprivate func capture(_ id: String) {
        guard !closed else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = view.bounds
        configuration.afterScreenUpdates = true
        view.takeSnapshot(with: configuration) { [weak self] image, _ in
            guard let self, !self.closed else { return }
            do {
                guard let png = image?.pngData() else { throw RemoteError.response }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("weq-download-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let file = directory.appendingPathComponent("WeQ-screenshot.png")
                do { try png.write(to: file, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: directory); throw error }
                self.captureResult(id, ok: true)
                self.shareFile(file)
            } catch { self.captureResult(id, ok: false) }
        }
    }

    private func captureResult(_ id: String, ok: Bool) {
        let payload: [String: Any] = ["id": id, "ok": ok, "delivery": "native", "error": ok ? "" : "无法生成截图"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        view.evaluateJavaScript("window.dispatchEvent(new CustomEvent('weq-remote-capture-result',{detail:\(json)}))", completionHandler: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let (_, file) = downloads.removeValue(forKey: ObjectIdentifier(download)) { removeDownload(file) }
        if !closed { showDownloadError() }
    }

    private func showDownloadError() {
        guard var presenter = view.window?.rootViewController else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        guard !(presenter is UIAlertController) else { return }
        let alert = UIAlertController(title: "文件未保存", message: "下载失败，请检查连接后重新下载。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenter.present(alert, animated: true)
    }

    private func removeDownload(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    func close() {
        closed = true
        startupTimeout?.cancel()
        startupTimeout = nil
        for (_, (download, file)) in downloads { download.cancel { _ in }; removeDownload(file) }
        downloads.removeAll()
        view.stopLoading()
        // 关闭时允许清空页面，避免来源限制拦住 about:blank，残留旧会话画面。
        view.navigationDelegate = nil
        view.uiDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "weqCapture")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "weqShell")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "weqStartup")
        onReady = nil
        onFailure = nil
        onLoading = nil
        onProgress = nil
        onDisconnect = nil
        view.loadHTMLString("", baseURL: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

struct WebContainer: UIViewRepresentable {
    let session: RemoteWebSession
    func makeUIView(context: Context) -> WKWebView { session.view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
