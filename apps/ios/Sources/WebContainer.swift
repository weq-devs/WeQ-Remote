import SwiftUI
import WebKit

@MainActor
final class RemoteWebSession: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let endpoint: URL
    private let fingerprint: String?

    init(configuration: WKWebViewConfiguration, endpoint: URL, fingerprint: String? = nil) {
        self.endpoint = endpoint
        self.fingerprint = fingerprint
        view = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = false
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard fingerprint != nil else { completionHandler(.performDefaultHandling, nil); return }
        if let credential = pinnedCredential(challenge, endpoint: endpoint, fingerprint: fingerprint) { completionHandler(.useCredential, credential) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              url.scheme == endpoint.scheme, url.host == endpoint.host, url.port == endpoint.port,
              url.user == nil, url.password == nil else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }

    func close() {
        view.stopLoading()
        // 关闭时允许清空页面，避免来源限制拦住 about:blank，残留旧会话画面。
        view.navigationDelegate = nil
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
