import SwiftUI
import WebKit

final class RemoteWebView: WKWebView {
    // WebKit 将编辑响应者的附加栏转交给 WebView；聊天操作由网页输入区提供。
    override var inputAccessoryView: UIView? { nil }
}

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
        guard message.frameInfo.isMainFrame, let owner,
              let url = message.frameInfo.request.url,
              RemoteWebPolicy.sameOrigin(url, endpoint: owner.endpoint) else { return }
        if message.body as? String == "menu" { owner.openMenu() }
        else if let value = message.body as? [String: String], let mode = value["dataSaverMode"], ["auto", "always", "never"].contains(mode) { owner.onNetworkPreference?(mode) }
    }
}

private final class RemoteExternalLinkHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteWebSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let owner, message.webView === owner.view,
              let value = message.body as? String, value.count <= 8192,
              let url = message.frameInfo.request.url,
              RemoteWebPolicy.sameOrigin(url, endpoint: owner.endpoint) else { return }
        owner.openRemoteLink(value)
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

private final class RemoteResourceHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteWebSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let owner, let url = message.frameInfo.request.url,
              RemoteWebPolicy.sameOrigin(url, endpoint: owner.endpoint),
              let progress = WebDownloadProgress(message: message.body) else { return }
        owner.receiveDownload(progress)
    }
}

private final class RemoteConnectionHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteWebSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let owner, message.webView === owner.view,
              message.body as? String == "failed", let url = message.frameInfo.request.url,
              RemoteWebPolicy.sameOrigin(url, endpoint: owner.endpoint) else { return }
        owner.onConnectionFailure?()
    }
}

private final class RemoteWindowLayoutHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteWebSession?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let owner, message.webView === owner.view,
              message.body as? String == "ready", let url = message.frameInfo.request.url,
              RemoteWebPolicy.sameOrigin(url, endpoint: owner.endpoint) else { return }
        owner.publishWindowLayout()
    }
}

@MainActor
final class RemoteWebSession: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static let windowLayoutScript = """
    window.webkit.messageHandlers.weqWindowLayout.postMessage('ready');
    """
    static let connectionHealthScript: String = {
        guard let url = Bundle.main.url(forResource: "web-connection-health", withExtension: "js") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()
    static let externalLinksScript = """
    (function(){
        if(window.__weqRemoteExternalLinks)return;
        window.__weqRemoteExternalLinks=true;
        window.weqRemoteLinks=Object.assign({},window.weqRemoteLinks,{open:function(url){window.webkit.messageHandlers.weqLinks.postMessage(String(url));}});
        var original=window.open;
        window.open=function(url,target,features){
            if(url&&url!=='about:blank'){
                try{
                    var parsed=new URL(url,location.href);
                    if(parsed.origin!==location.origin&&/^(https?:|mailto:|tel:|tencent:|mqqapi:)$/.test(parsed.protocol)){
                        window.weqRemoteLinks.open(parsed.href);
                        return null;
                    }
                }catch(error){return null;}
            }
            return original.call(window,url,target,features);
        };
    })();
    """
    let view: WKWebView
    let endpoint: URL
    var onNetworkPreference: ((String) -> Void)?
    private let fingerprint: String?
    private var downloads: [ObjectIdentifier: (WKDownload, URL)] = [:]
    private var closed = false
    private var startupTimeout: Task<Void, Never>?
    private var startupFinished = false
    private var startupReported = false
    private var navigationGeneration = 0
    private var windowLayout = RemoteWindowLayout()
    private var nativeMedia: RemoteNativeMedia?
    private var dialogQueue: [(id: UUID, alert: UIAlertController, cancel: () -> Void)] = []
    private var activeDialog: (id: UUID, alert: UIAlertController, cancel: () -> Void)?
    // 正式页面准备完成才切到全屏；HTML 加载完成仍留在首页。
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onLoading: (() -> Void)?
    var onProgress: ((String) -> Void)?
    var onDownload: ((WebDownloadProgress?) -> Void)?
    var onMenu: (() -> Void)?
    var onConnectionFailure: (() -> Void)?

    func updateConnectionHealth(warning: ConnectionHealth.Warning?, recovery: Int = 0) {
        guard !closed else { return }
        let state = warning == .network ? "network" : warning == .connection ? "connection" : "connected"
        view.evaluateJavaScript("window.weqRemoteConnection={state:'\(state)',recovery:\(recovery)};window.dispatchEvent(new Event('weq-remote-connection'));", completionHandler: nil)
    }

    func updateWindowLayout(_ layout: RemoteWindowLayout) {
        guard !closed, layout != windowLayout else { return }
        windowLayout = layout
        publishWindowLayout()
    }

    fileprivate func publishWindowLayout(completion: (() -> Void)? = nil) {
        guard !closed else { return }
        view.evaluateJavaScript("window.weqRemoteWindowLayout=\(windowLayout.json);window.dispatchEvent(new Event('weq-remote-window-layout'));", completionHandler: { _, _ in completion?() })
    }

    func updateNetworkCost(_ cost: RemoteNetworkCost) {
        guard !closed else { return }
        let content = view.configuration.userContentController
        let scripts = content.userScripts.filter { !$0.source.hasPrefix("window.weqRemoteNetworkCost=") }
        content.removeAllUserScripts()
        content.addUserScript(WKUserScript(source: cost.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for script in scripts { content.addUserScript(script) }
        view.evaluateJavaScript(cost.script, completionHandler: nil)
    }

    init(configuration: WKWebViewConfiguration, endpoint: URL, fingerprint: String? = nil, networkCost: RemoteNetworkCost = .unknown) {
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        // 网页背景已有 playsinline；iPhone 还需在创建 WebView 前允许页内播放。
        configuration.allowsInlineMediaPlayback = true
        configuration.applicationNameForUserAgent = "WeQRemote"
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        view = RemoteWebView(frame: .zero, configuration: configuration)
        super.init()
        configuration.userContentController.addUserScript(WKUserScript(
            source: networkCost.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let capture = RemoteCaptureHandler()
        capture.owner = self
        configuration.userContentController.add(capture, name: "weqCapture")
        let shell = RemoteShellHandler()
        shell.owner = self
        configuration.userContentController.add(shell, name: "weqShell")
        let links = RemoteExternalLinkHandler()
        links.owner = self
        configuration.userContentController.add(links, name: "weqLinks")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.externalLinksScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let startup = RemoteStartupHandler()
        startup.owner = self
        configuration.userContentController.add(startup, name: "weqStartup")
        let resources = RemoteResourceHandler()
        resources.owner = self
        configuration.userContentController.add(resources, name: "weqResources")
        let connection = RemoteConnectionHandler()
        connection.owner = self
        configuration.userContentController.add(connection, name: "weqConnection")
        let windowLayout = RemoteWindowLayoutHandler()
        windowLayout.owner = self
        configuration.userContentController.add(windowLayout, name: "weqWindowLayout")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.windowLayoutScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.connectionHealthScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let url = Bundle.main.url(forResource: "web-startup-progress", withExtension: "js"),
           let source = try? String(contentsOf: url, encoding: .utf8) {
            configuration.userContentController.addUserScript(WKUserScript(
                source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.addEventListener('weq-remote-startup',function(){if(window.weqRemoteStartup)window.webkit.messageHandlers.weqStartup.postMessage(window.weqRemoteStartup)});",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.addUserScript(WKUserScript(
            source: "window.weqRemoteConnection={state:'connected'};window.weqRemoteShell={openMenu:function(){window.webkit.messageHandlers.weqShell.postMessage('menu')},connectionFailed:function(){window.webkit.messageHandlers.weqConnection.postMessage('failed')}};",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if endpoint.scheme == "http" {
            let media = RemoteNativeMedia(view: view, endpoint: endpoint)
            nativeMedia = media
            configuration.userContentController.add(media, name: "weqMedia")
            configuration.userContentController.addUserScript(WKUserScript(
                source: RemoteNativeMedia.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
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
        onProgress?("正在下载网页资源")
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationGeneration += 1
        cancelWebDialogs()
        nativeMedia?.stopAll()
        startupFinished = false
        startupReported = false
        onDownload?(nil)
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
        startupReported = true
        if state == "loading" {
            onProgress?(String((message ?? "正在初始化 WeQ 页面").prefix(100)))
        } else if state == "ready" || state == "action-required" {
            startupFinished = true
            startupTimeout?.cancel()
            if view.url == nil || (windowLayout.width > 0 && windowLayout.height > 0 && !windowLayout.hasCornerOverlap) {
                onReady?()
            } else {
                // 首次显示前补发几何值，并等待网页布局提交；不重建 WebView。
                let generation = navigationGeneration
                publishWindowLayout { [weak self] in
                    guard let self, !self.closed, generation == self.navigationGeneration else { return }
                    self.view.callAsyncJavaScript("await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))); return true;", arguments: [:], in: nil, in: .page) { [weak self] _ in
                        guard let self, !self.closed, generation == self.navigationGeneration else { return }
                        self.onReady?()
                    }
                }
            }
        } else if state == "error" {
            startupFinished = true
            startupTimeout?.cancel()
            onFailure?(NSError(domain: "WeQRemoteStartup", code: 1,
                userInfo: [NSLocalizedDescriptionKey: String((message ?? "WeQ 页面启动失败，请重试。").prefix(500))]))
        }
    }

    func receiveDownload(_ progress: WebDownloadProgress) {
        guard !closed, !startupFinished else { return }
        onDownload?(progress)
        if !startupReported {
            onProgress?(progress.downloading ? "正在下载网页资源" : "正在执行网页脚本")
        }
    }

    fileprivate func openMenu() {
        guard !closed else { return }
        onMenu?()
    }

    func reload() {
        guard !closed else { return }
        onLoading?()
        view.reload()
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
        guard !closed, RemoteWebPolicy.external(url) else { return }
        UIApplication.shared.open(url)
    }

    fileprivate func openRemoteLink(_ value: String) {
        guard let url = URL(string: value), !sameOrigin(url) else { return }
        openExternal(url)
    }

    private func enqueueWebDialog(_ alert: UIAlertController, id: UUID, cancel: @escaping () -> Void) {
        guard !closed, view.window != nil else { cancel(); return }
        dialogQueue.append((id, alert, cancel))
        showNextWebDialog()
    }

    private func showNextWebDialog() {
        guard !closed, activeDialog == nil, !dialogQueue.isEmpty else { return }
        guard var presenter = view.window?.rootViewController else { cancelWebDialogs(); return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let next = dialogQueue.removeFirst()
        activeDialog = next
        presenter.present(next.alert, animated: true)
    }

    private func finishWebDialog(_ id: UUID) {
        guard activeDialog?.id == id else { return }
        let alert = activeDialog?.alert
        activeDialog = nil
        alert?.dismiss(animated: true) { [weak self] in self?.showNextWebDialog() }
    }

    private func cancelWebDialogs() {
        let active = activeDialog
        let pending = dialogQueue
        activeDialog = nil; dialogQueue.removeAll()
        active?.cancel()
        active?.alert.dismiss(animated: false)
        for item in pending { item.cancel() }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let id = UUID(), result = WebDialogCompletion<Void>(cancelled: ()) { completionHandler() }
        let alert = UIAlertController(title: "WeQ", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in
            result.finish(()); self?.finishWebDialog(id)
        })
        enqueueWebDialog(alert, id: id, cancel: result.cancel)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let id = UUID(), result = WebDialogCompletion<Bool>(cancelled: false, callback: completionHandler)
        let alert = UIAlertController(title: "WeQ", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            result.cancel(); self?.finishWebDialog(id)
        })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self] _ in
            result.finish(true); self?.finishWebDialog(id)
        })
        enqueueWebDialog(alert, id: id, cancel: result.cancel)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let id = UUID(), result = WebDialogCompletion<String?>(cancelled: nil, callback: completionHandler)
        let alert = UIAlertController(title: "WeQ", message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self] _ in
            result.cancel(); self?.finishWebDialog(id)
        })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { [weak self, weak alert] _ in
            result.finish(alert?.textFields?.first?.text ?? ""); self?.finishWebDialog(id)
        })
        enqueueWebDialog(alert, id: id, cancel: result.cancel)
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
        cancelWebDialogs()
        nativeMedia?.close()
        nativeMedia = nil
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
        view.configuration.userContentController.removeScriptMessageHandler(forName: "weqLinks")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "weqStartup")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "weqResources")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "weqConnection")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "weqWindowLayout")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "weqMedia")
        onReady = nil
        onFailure = nil
        onLoading = nil
        onProgress = nil
        onDownload = nil
        onMenu = nil
        onConnectionFailure = nil
        view.loadHTMLString("", baseURL: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

struct WebContainer: View {
    let session: RemoteWebSession
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        GeometryReader { geometry in
            if #available(iOS 26.0, *) {
                let leading = geometry.containerCornerInsets.topLeading
                let trailing = geometry.containerCornerInsets.topTrailing
                let left = direction == .leftToRight ? leading : trailing
                let right = direction == .leftToRight ? trailing : leading
                RemoteWebContent(session: session, layout: RemoteWindowLayout(
                    width: geometry.size.width, height: geometry.size.height,
                    topLeft: .init(width: left.width, height: left.height),
                    topRight: .init(width: right.width, height: right.height)))
            } else {
                RemoteWebContent(session: session, layout: RemoteWindowLayout(
                    width: geometry.size.width, height: geometry.size.height))
            }
        }
    }
}

private struct RemoteWebContent: UIViewRepresentable {
    let session: RemoteWebSession
    let layout: RemoteWindowLayout
    func makeUIView(context: Context) -> WKWebView { session.view }
    func updateUIView(_ uiView: WKWebView, context: Context) { session.updateWindowLayout(layout) }
}
