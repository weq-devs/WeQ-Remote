import Combine
import Foundation
import TailscaleKit
import CryptoKit
import WebKit
import Network

private struct SilentLogger: LogSink {
    var logFileHandle: Int32? { -1 }
    func log(_ message: String) {}
}

private struct TailnetStatus: Decodable {
    let BackendState: String
    let AuthURL: String?
    let TailscaleIPs: [String]?

    var loginURL: URL? {
        guard let AuthURL, let url = URL(string: AuthURL), url.scheme == "https",
              url.host == "login.tailscale.com", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        return url
    }
}

@MainActor
final class EmbeddedNetwork: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var message = "未启动"
    @Published private(set) var loginURL: URL?
    @Published private(set) var address: String?
    private var node: TailscaleNode?
    private var revision = 0
    private var refreshing = false
    private var closing: Task<Void, Never>?
    private let controlURL: String
    private var enrollmentKey: String?
    private var stateName: String?
    let webDataStore = RemoteWebDataStore()

    init(controlURL: String? = nil) {
        self.controlURL = controlURL ?? Self.integrationControl ?? kDefaultControlURL
        if self.controlURL == kDefaultControlURL,
           let saved = UserDefaults.standard.string(forKey: "enrollmentState"),
           saved.range(of: "\\AWeQRemoteNetwork-Enrolled-[a-f0-9]{64}\\z", options: .regularExpression) != nil { stateName = saved }
    }

    static var integrationControl: String? {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--remote-ts-integration-test"),
              let value = ProcessInfo.processInfo.environment["WEQ_REMOTE_TEST_CONTROL"],
              let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.path.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return value
        #else
        return nil
        #endif
    }

    func start() async {
        guard !enabled else { return }
        enabled = true
        message = "正在连接"
        await refresh()
    }

    static func enrollmentStateName(_ key: String) -> String {
        "WeQRemoteNetwork-Enrolled-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // 只在用户确认后调用；新 Key 用独立节点，避免已有登录身份忽略新 Key。
    func enroll(authKey: String, expiresAt: Double) async throws {
        guard Self.integrationControl == nil, PairingInvitation.validAuthKey(authKey),
              expiresAt > Date().timeIntervalSince1970 * 1000 else { throw RemoteError.enrollment }
        await stop()
        try Task.checkCancellation()
        let previousStateName = stateName
        stateName = Self.enrollmentStateName(authKey)
        enrollmentKey = authKey
        enabled = true
        let generation = revision
        let deadline = ContinuousClock.now + .seconds(45)
        do {
            while ContinuousClock.now < deadline, expiresAt > Date().timeIntervalSince1970 * 1000 {
                try Task.checkCancellation()
                guard generation == revision, enabled else { throw CancellationError() }
                await refresh()
                try Task.checkCancellation()
                guard generation == revision, enabled else { throw CancellationError() }
                if connected {
                    UserDefaults.standard.set(stateName, forKey: "enrollmentState")
                    return
                }
                if loginURL != nil || message == "等待网络管理员批准" || message == "网络连接失败，请重试" { break }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch {
            if generation == revision {
                await stop(waitForClose: false)
                stateName = previousStateName
            }
            throw error
        }
        if generation == revision { await stop(waitForClose: false); stateName = previousStateName }
        throw RemoteError.enrollment
    }

    func refresh() async {
        guard enabled, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let generation = revision
        do {
            if let closing { await closing.value }
            guard generation == revision, enabled else { return }
            closing = nil
            if node == nil {
                let control = controlURL
                let authKey = enrollmentKey
                enrollmentKey = nil
                let directoryName = stateName ?? (control == kDefaultControlURL ? "WeQRemoteNetwork" : "WeQRemoteNetwork-Integration")
                let created = try await Task.detached(priority: .utility) {
                    var directory = try FileManager.default.url(for: .applicationSupportDirectory,
                        in: .userDomainMask, appropriateFor: nil, create: true)
                        .appendingPathComponent(directoryName, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try directory.setResourceValues(values)
                    return try TailscaleNode(config: Configuration(hostName: "weq-remote-ios", path: directory.path,
                        authKey: authKey, controlURL: control, ephemeral: false), logger: SilentLogger())
                }.value
                guard generation == revision, enabled else { try? await created.close(); return }
                node = created
            }
            guard let node else { throw RemoteError.network }
            let raw = try await node.statusJSON()
            guard raw.count < 1_048_576, generation == revision else { return }
            let status = try JSONDecoder().decode(TailnetStatus.self, from: raw)
            connected = status.BackendState == "Running"
            loginURL = status.loginURL
            address = connected ? status.TailscaleIPs?.first : nil
            switch status.BackendState {
            case "Running": message = "已连接"
            case "NeedsLogin": message = "等待网络登录"
            case "NeedsMachineAuth": message = "等待网络管理员批准"
            default: message = "正在连接"
            }
        } catch {
            if generation == revision { connected = false; message = "网络连接失败，请重试" }
        }
    }

    func session(timeout: TimeInterval? = nil) async throws -> URLSession {
        guard connected, let node else { throw RemoteError.network }
        let configuration = Self.configuration()
        if let timeout { configuration.timeoutIntervalForResource = timeout }
        let generation = revision
        try await configuration.proxyVia(node)
        guard generation == revision, connected else { throw CancellationError() }
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func webSession(endpoint: URL, token: String, fingerprint: String? = nil) async throws -> RemoteWebSession {
        guard (fingerprint != nil ? PairingInvitation.isDirectEndpoint(endpoint) : PairingInvitation.isTailnetEndpoint(endpoint)),
              token.count == 64, token.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw RemoteError.network }
        let generation = revision
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = webDataStore.dataStore(endpoint: endpoint, token: token, fingerprint: fingerprint)
        configuration.websiteDataStore.proxyConfigurations = []
        if fingerprint == nil {
        guard connected, let node else { throw RemoteError.network }
        let loopback = try await node.loopback()
        guard let ip = loopback.ip, let port = loopback.port,
              let proxyPort = NWEndpoint.Port(rawValue: UInt16(port)), generation == revision else { throw RemoteError.network }
        var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: NWEndpoint.Host(ip), port: proxyPort))
        proxy.applyCredential(username: "tsnet", password: loopback.proxyCredential)
        proxy.allowFailover = false
        configuration.websiteDataStore.proxyConfigurations = [proxy]
        }
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let cookieValue = "weq_remote=\(token); HttpOnly; SameSite=Strict; Path=/" + (endpoint.scheme == "https" ? "; Secure" : "")
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": cookieValue], for: endpoint).first else { throw RemoteError.credential }
        await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        guard generation == revision, fingerprint != nil || connected else { throw CancellationError() }
        let session = RemoteWebSession(configuration: configuration, endpoint: endpoint, fingerprint: fingerprint)
        session.view.load(URLRequest(url: endpoint))
        return session
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    func stop(disable: Bool = true, waitForClose: Bool = true) async {
        revision += 1
        enrollmentKey = nil
        if disable { enabled = false }
        connected = false
        loginURL = nil
        address = nil
        message = disable ? "未启动" : "已暂停"
        let previous = node
        node = nil
        if let previous { closing = Task { try? await previous.close() } }
        if waitForClose { await closing?.value }
    }
}
