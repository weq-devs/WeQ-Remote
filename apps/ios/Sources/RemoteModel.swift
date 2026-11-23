import Combine
import Foundation
import UIKit
import Network

struct RemoteHomeFailure {
    enum Kind {
        case pairing, connection, verification, authorization, webLoad, webStartup, webTimeout

        var title: String {
            switch self {
            case .pairing: "配对未完成"
            case .connection: "暂时连不上电脑"
            case .verification: "无法验证电脑连接"
            case .authorization: "电脑未授权这台手机"
            case .webLoad: "WeQ 页面加载失败"
            case .webStartup: "WeQ 界面启动失败"
            case .webTimeout: "WeQ 页面加载超时"
            }
        }

        var retriesWeb: Bool { self == .webLoad || self == .webStartup || self == .webTimeout }
    }

    let kind: Kind
    let detail: String
}

@MainActor
final class RemoteModel: ObservableObject {
    @Published var invitationText = ""
    @Published private(set) var busy = false
    @Published private(set) var code: String?
    @Published private(set) var computerAddress: String?
    @Published private(set) var connected = false
    @Published private(set) var paired = false
    @Published private(set) var message = "未配对"
    @Published private(set) var latency: Int?
    @Published private(set) var checkedAt: Date?
    @Published private(set) var failure: RemoteHomeFailure?
    var error: String? { failure?.detail }
    @Published private(set) var webSession: RemoteWebSession?
    @Published private(set) var webReady = false
    @Published private(set) var webMenuReady = false
    @Published private(set) var openingCachedWeb = false
    @Published private(set) var webLoadingStage = WebDownloadProgress.loadingMessage
    @Published private(set) var webDownload: WebDownloadProgress?
    @Published private(set) var webDevelopmentProgress: WebDevelopmentProgress?
    @Published private(set) var checkingWebReload = false
    @Published var webReloadFailed = false
    @Published private(set) var rememberedComputer = false
    @Published private(set) var health = ConnectionHealth()
    @Published private(set) var checkingUpdates = false
    @Published private(set) var updateMessage = "尚未检查"
    @Published private(set) var releaseURL: URL?
    @Published private(set) var updateDownloads: [UpdateMirror] = []
    @Published private(set) var includePrerelease = UserDefaults.standard.bool(forKey: "checkPrerelease")
    @Published var showingDetails = false
    let network: EmbeddedNetwork
    private var api: RemoteAPI?
    private var credential: DeviceCredential?
    private var polling: Task<Void, Never>?
    private var revision = 0
    private var fingerprint: String?
    private var endpoints: [URL]?
    private var routeFingerprint: String?
    private var reconnectPaused = false
    private var probingSessions: [UUID: URLSession] = [:]
    private var healthMonitorID: UUID?
    private var healthDeadline: Task<Void, Never>?
    private var eventCheck: Task<Void, Never>?
    private var eventCheckID: UUID?
    private var lastEventCheck: TimeInterval?
    private var healthEpoch = 0
    private var connectionRecovery = 0
    private var networkCostMonitorID: UUID?

    func monitorConnectionHealth() async {
        let costID = UUID()
        networkCostMonitorID = costID
        let monitor = NWPathMonitor()
        let updates = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor.pathUpdateHandler = { [weak self] path in
            let cost = RemoteNetworkCost(available: path.status == .satisfied, constrained: path.isConstrained, metered: path.isExpensive)
            Task { @MainActor [weak self] in
                guard let self, self.networkCostMonitorID == costID else { return }
                self.network.networkCost = cost
                self.webSession?.updateNetworkCost(cost)
            }
            updates.continuation.yield(path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "io.github.weqdevs.remote.connection"))
        defer {
            if networkCostMonitorID == costID { networkCostMonitorID = nil }
            monitor.cancel()
            updates.continuation.finish()
        }
        await monitorConnectionHealth(paths: updates.stream)
    }

    func monitorConnectionHealth(paths: AsyncStream<Bool>) async {
        let id = UUID()
        healthEpoch += 1
        healthMonitorID = id
        health.resume()
        scheduleConnectionWarning()
        if webReady { requestConnectionCheck(immediately: true) }
        defer {
            if healthMonitorID == id {
                healthMonitorID = nil
                healthDeadline?.cancel()
                healthDeadline = nil
                eventCheck?.cancel()
                eventCheck = nil
                eventCheckID = nil
                health.suspend()
            }
        }
        for await available in paths {
            guard !Task.isCancelled, healthMonitorID == id else { return }
            let changed = health.networkAvailable != available
            health.networkChanged(available: available)
            publishConnectionHealth()
            scheduleConnectionWarning()
            if changed { requestConnectionCheck(immediately: true) }
        }
    }

    private func scheduleConnectionWarning() {
        healthDeadline?.cancel()
        healthDeadline = nil
        guard let id = healthMonitorID, webReady, let deadline = health.nextDeadline else { return }
        healthDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime))) } catch { return }
            guard let self, self.healthMonitorID == id, self.webReady else { return }
            self.health.evaluate()
            self.publishConnectionHealth()
            self.scheduleConnectionWarning()
        }
    }

    private func requestConnectionCheck(immediately: Bool = false) {
        guard healthMonitorID != nil, eventCheck == nil, !reconnectPaused else { return }
        let id = UUID()
        eventCheckID = id
        eventCheck = Task { [weak self] in
            defer {
                if self?.eventCheckID == id {
                    self?.eventCheck = nil
                    self?.eventCheckID = nil
                }
            }
            if !immediately, let last = self?.lastEventCheck {
                let delay = max(0, last + 5 - ProcessInfo.processInfo.systemUptime)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            while let self, self.busy {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            guard !Task.isCancelled, let self, self.healthMonitorID != nil else { return }
            self.lastEventCheck = ProcessInfo.processInfo.systemUptime
            await self.reconnect()
            while !Task.isCancelled, self.webReady, self.health.failedChecks > 0, self.healthMonitorID != nil, !self.reconnectPaused {
                do { try await Task.sleep(for: .seconds(self.health.checkInterval)) } catch { return }
                await self.reconnect()
            }
        }
    }

    private func connectionFailed() {
        guard webReady, healthMonitorID != nil else { return }
        health.failed()
        scheduleConnectionWarning()
    }

    private func publishConnectionHealth() {
        guard webReady else { return }
        webSession?.updateConnectionHealth(warning: health.warning, recovery: connectionRecovery)
    }

    var connectionCheckInterval: TimeInterval { health.checkInterval }

    var isConnecting: Bool { checkingWebReload || busy || code != nil || (webSession != nil && !webReady) }

    var appVersion: String {
        Bundle.main.infoDictionary?["WeQReleaseVersion"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
    }
    var versionInfo: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        return "WeQ Remote \(appVersion) (\(build)) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
    }
    private var deviceInfo: RemoteDeviceInfo {
        var system = utsname()
        uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { bytes in
            String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        }
        return RemoteDeviceInfo(platform: "ios", model: identifier ?? UIDevice.current.model,
            osVersion: UIDevice.current.systemVersion, appVersion: appVersion,
            appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知")
    }
    var connectionRoute: String {
        guard let api else { return "未选择" }
        return api.endpoint.scheme == "http" ? "内嵌 Tailscale" : "系统网络（HTTPS）"
    }
    var tailscaleStatus: String {
        if api?.endpoint.scheme == "https" {
            return network.enabled ? "\(network.message)（未用于当前入口）" : "未使用（系统网络）"
        }
        return network.message
    }
    var connectionDetails: String {
        let checked = health.checkedAt?.formatted(date: .omitted, time: .standard) ?? "尚未验证"
        let latency = health.latency.map { "\($0) ms" } ?? "—"
        return "连接：\(api == nil ? "未连接" : health.status)\n电脑：\(api?.endpoint.absoluteString ?? "未选择")\n连接方式：\(connectionRoute)\nTailscale：\(tailscaleStatus)\n最近成功：\(checked)\n请求耗时：\(latency)\n\(versionInfo)"
    }

    func checkUpdates() async {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        releaseURL = nil
        updateDownloads = []
        defer { checkingUpdates = false }
        do {
            guard let current = ReleaseVersion(appVersion) else { throw RemoteError.response }
            guard let url = Bundle.main.url(forResource: "update-mirrors", withExtension: "json") else { throw RemoteError.response }
            let prefixes = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
            updateMessage = "正在读取发布版本…"
            let release = try await UpdateMirrors.release(includePrerelease: includePrerelease)
            updateMessage = "测速中（\(prefixes.count) 个源）"
            let ranked = try await UpdateMirrors.resolve(prefixes: prefixes, release: release, sample: !network.dataSaverEnabled)
            guard let best = ranked.first else { throw RemoteError.response }
            let version = best.manifest.version
            releaseURL = URL(string: "https://github.com/weq-devs/WeQ-Remote/releases/tag/v\(version.text)")
            if version > current { updateDownloads = ranked }
            let result = version > current ? "发现新版本 v\(version.text)\n当前 v\(appVersion) → v\(version.text)" : version == current ? "已是最新版本\n当前 v\(appVersion)" : "当前 v\(appVersion)，最新发布为 v\(version.text)"
            updateMessage = "\(result)\n已自动选择加速站 \(best.label)（已测速）"
            if version > current { updateMessage += "\n下载为未签名 IPA，需签名后安装。" }
        } catch { updateMessage = "检查更新失败，无法读取发布版本或连接加速站，请检查网络后重试。" }
    }

    func setPrerelease(_ enabled: Bool) {
        guard !checkingUpdates else { return }
        UserDefaults.standard.set(enabled, forKey: "checkPrerelease")
        includePrerelease = enabled
        updateMessage = "尚未检查"
        updateDownloads = []
        releaseURL = nil
    }

    func resumeReconnect() { reconnectPaused = false }

    func suspend() {
        healthEpoch += 1
        healthDeadline?.cancel()
        healthDeadline = nil
        health.suspend()
        // 已配对的网页与节点留在内存；前台恢复只验证，不重建页面。
        guard webSession == nil else { return }
        let wasPaused = reconnectPaused
        let previousFailure = failure
        disconnect()
        if let previousFailure, previousFailure.kind.retriesWeb || previousFailure.kind == .authorization {
            failure = previousFailure
        }
        if !wasPaused { resumeReconnect() }
    }

    func preparePairing() {
        guard !reconnectPaused else { return }
        reconnectPaused = true
        if polling == nil, webSession == nil {
            revision += 1
            api?.session.invalidateAndCancel()
            api = nil
            credential = nil
            busy = false
        }
    }

    func reconnect(manually: Bool = false) async {
        guard !reconnectPaused, !busy, polling == nil else { return }
        guard manually || failure?.kind.retriesWeb != true else { return }
        if !webReady { failure = nil; checkedAt = nil }
        if api != nil { await refresh(); return }
        let generation = revision
        busy = true
        defer { if generation == revision { busy = false } }
        do {
            guard let saved = try SavedConnection.load() else {
                rememberedComputer = false
                openingCachedWeb = false
                return
            }
            rememberedComputer = true
            if webSession == nil, !testMode,
               let cached = try? await network.webSession(token: saved.token) {
                guard generation == revision, !Task.isCancelled else {
                    cached.close()
                    network.closeWeb()
                    return
                }
                adoptWebSession(cached, cached: true)
            }
            if webSession == nil { openingCachedWeb = false }
            message = "正在连接电脑"
            let selection = try await selectConnection(saved.endpoints ?? [saved.endpoint], pin: saved.routeFingerprint ?? saved.fingerprint, probe: restoreProbe(for: saved.endpoints), token: saved.token)
            guard generation == revision else { selection.api.session.invalidateAndCancel(); return }
            endpoints = saved.endpoints; routeFingerprint = saved.routeFingerprint
            fingerprint = selection.api.endpoint.scheme == "https" ? saved.routeFingerprint ?? saved.fingerprint : nil
            api = selection.api
            credential = try DeviceCredential(token: saved.token)
            computerAddress = selection.api.endpoint.host
            paired = true
            await refresh(verified: selection)
            if !connected { api?.session.invalidateAndCancel(); api = nil }
        } catch {
            if generation == revision, !Task.isCancelled {
                if webSession == nil { openingCachedWeb = false }
                if case RemoteError.unauthorized = error { fail(error) }
                else {
                    api?.session.invalidateAndCancel(); api = nil
                    connectionFailed()
                    if failure?.kind.retriesWeb != true { showConnectionFailure(error) }
                }
            }
        }
    }

    private func connectionSession(endpoint: URL, fingerprint: String?, timeout: TimeInterval? = nil) async throws -> URLSession {
        if let fingerprint {
            let configuration = EmbeddedNetwork.configuration()
            if let timeout { configuration.timeoutIntervalForResource = timeout }
            return URLSession(configuration: configuration, delegate: NoRedirectDelegate(endpoint: endpoint, fingerprint: fingerprint), delegateQueue: nil)
        }
        await network.start()
        let generation = revision
        let deadline = ContinuousClock.now + .seconds(45)
        while !network.connected && ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard generation == revision else { throw CancellationError() }
            await network.refresh()
            if network.loginURL != nil { throw RemoteError.enrollment }
            try await Task.sleep(for: .milliseconds(500))
        }
        return try await network.session(timeout: timeout)
    }

    private func selectConnection(_ endpoints: [URL], pin: String?, probe: RemoteProbe, token: String? = nil, invitation: PairingInvitation? = nil, timeout: TimeInterval? = nil) async throws -> RemoteSelection {
        let generation = revision
        var enrolled = false
        let (_, selected) = try await selectRemoteRoute(endpoints, discard: { $0.api.session.invalidateAndCancel() }) { endpoint in
            try Task.checkCancellation()
            guard generation == self.revision else { throw CancellationError() }
            if !enrolled, invitation?.isMultiRoute == true, endpoint.scheme == "http", let authKey = invitation?.authKey, let expiresAt = invitation?.expiresAt {
                try await self.network.enroll(authKey: authKey, expiresAt: expiresAt)
                enrolled = true
            }
            let session = try await self.connectionSession(endpoint: endpoint, fingerprint: endpoint.scheme == "https" ? pin : nil, timeout: timeout)
            let probeID = UUID()
            self.probingSessions[probeID] = session
            defer { self.probingSessions.removeValue(forKey: probeID) }
            do {
                try Task.checkCancellation()
                guard generation == self.revision else { throw CancellationError() }
                let api = RemoteAPI(endpoint: endpoint, session: session, deviceInfo: self.deviceInfo)
                var status: ComputerStatus?
                var latencyMillis: Int?
                switch probe {
                case .status where token != nil:
                    // 已配对设备的一读既用于选路也用于本次连接，不再重复请求。
                    let start = ContinuousClock.now
                    let value: ComputerStatus = try await api.request("v1/status", token: token, timeout: timeout ?? 12)
                    try value.validate()
                    latencyMillis = elapsedMillis(ContinuousClock.now - start)
                    status = value
                case .hello, .status:
                    // 未批准的设备不能读状态，只用 hello 确认路径可达。
                    let hello: RemoteHello = try await api.request("v1/hello", timeout: 3)
                    try hello.validate()
                case .none:
                    break
                }
                try Task.checkCancellation()
                guard generation == self.revision else { throw CancellationError() }
                return RemoteSelection(api: api, status: status, latencyMillis: latencyMillis)
            } catch { session.invalidateAndCancel(); throw error }
        }
        return selected
    }

    func adoptWebSession(_ session: RemoteWebSession, cached: Bool = false) {
        session.onNetworkPreference = { [weak self] mode in self?.network.dataSaverMode = mode }
        openingCachedWeb = cached
        webReady = false
        webMenuReady = false
        webLoadingStage = WebDownloadProgress.loadingMessage
        webDownload = nil
        webDevelopmentProgress = nil
        session.onDownload = { [weak self, weak session] progress in
            guard let self, self.webSession === session else { return }
            self.webDownload = progress
        }
        session.onDevelopmentProgress = { [weak self, weak session] progress in
            guard let self, self.webSession === session,
                  progress.completed > (self.webDevelopmentProgress?.completed ?? -1) else { return }
            self.webDevelopmentProgress = progress
        }
        session.onProgress = { [weak self, weak session] stage in
            guard let self, self.webSession === session, self.webLoadingStage != stage else { return }
            self.webLoadingStage = stage
        }
        session.onReady = { [weak self, weak session] in
            guard let self, self.webSession === session else { return }
            self.webReady = true
            self.openingCachedWeb = false
            self.health.resume()
            if self.failure != nil && !self.connected { self.health.failed() }
            self.scheduleConnectionWarning()
            self.publishConnectionHealth()
            self.webDownload = nil
            self.webDevelopmentProgress = nil
            self.failure = nil
        }
        session.onFailure = { [weak self, weak session] error in
            guard let self, self.webSession === session else { return }
            if (error as? URLError)?.code == .cancelled { return }
            if self.webReady {
                self.connectionFailed()
                self.requestConnectionCheck()
            } else { self.failWebLoad(error) }
        }
        session.onConnectionFailure = { [weak self, weak session] in
            guard let self, self.webSession === session, self.webReady else { return }
            self.connectionFailed()
            self.requestConnectionCheck()
        }
        session.onLoading = { [weak self, weak session] in
            guard let self, self.webSession === session else { return }
            self.webReady = false
            self.webMenuReady = false
            self.webDownload = nil
            self.webDevelopmentProgress = nil
            self.failure = nil
        }
        session.onMenu = { [weak self] in self?.showingDetails = true }
        session.onMenuReady = { [weak self, weak session] ready in
            guard let self, self.webSession === session, self.webMenuReady != ready else { return }
            self.webMenuReady = ready
        }
        webSession = session
    }

    func retryWebFromMenu() async {
        guard !checkingWebReload else { return }
        if let session = webSession {
            checkingWebReload = true
            webReloadFailed = false
            let checked = await network.checkWebReload()
            guard webSession === session else { return }
            checkingWebReload = false
            if checked {
                webLoadingStage = WebDownloadProgress.loadingMessage
                session.reload()
            } else if webReady {
                webReloadFailed = true
            } else {
                failWebLoad(RemoteWebStartupError.reported("无法从电脑检查或准备网页更新，请稍后重试。"))
            }
            return
        }
        disconnect()
        await network.stop()
        resumeReconnect()
        await reconnect(manually: true)
    }

    private func failWebLoad(_ error: Error) {
        checkingWebReload = false
        let recovery = checkedAt != nil
            ? "本次已连到电脑，无需重新扫码。"
            : "可使用已保存的配对重试，无需重新扫码。"
        switch error as? RemoteWebStartupError {
        case .reported(let detail)?:
            // 旧网页用文案区分资源与渲染异常；有具体诊断的其他消息仍原样显示。
            switch detail {
            case "WeQ 界面资源加载失败，自动重试一次后仍未成功，请检查电脑与网络后重试。":
                failure = .init(kind: .webLoad, detail: "网页资源自动重试后仍未加载完成。")
            case "WeQ 界面启动异常，请重新连接。", nil:
                failure = .init(kind: .webStartup, detail: recovery)
            default:
                failure = .init(kind: .webStartup, detail: detail ?? recovery)
            }
        case .timeout?:
            failure = .init(kind: .webTimeout, detail: "最后进度：\(webLoadingStage)。\(recovery)")
        default:
            failure = .init(kind: .webLoad, detail: recovery)
        }
        webDownload = nil
        webDevelopmentProgress = nil
        webSession?.close()
        network.closeWeb()
        webSession = nil
        webReady = false
        webMenuReady = false
        openingCachedWeb = false
        connected = false
        message = failure?.kind.title ?? "网页加载失败"
    }

    func forget() {
        let saved = try? SavedConnection.load()
        network.clearWebCache()
        network.webDataStore.clearBusinessCache(token: saved?.token)
        network.webDataStore.clear()
        if let saved {
            for endpoint in saved.endpoints ?? [saved.endpoint] {
                let pin = endpoint.scheme == "https" ? saved.routeFingerprint ?? saved.fingerprint : nil
                _ = network.webDataStore.dataStore(endpoint: endpoint, token: saved.token, fingerprint: pin)
                network.webDataStore.clear()
            }
        }
        SavedConnection.delete()
        rememberedComputer = false
        disconnect()
    }

    init(network: EmbeddedNetwork) {
        self.network = network
        rememberedComputer = (try? SavedConnection.load()) != nil
        openingCachedWeb = rememberedComputer && !testMode && EmbeddedNetwork.integrationControl == nil &&
            !ProcessInfo.processInfo.arguments.contains("--remote-web-smoke-test")
    }

    // 仅模拟器 Debug 构建接受回环测试配置；真机/Release 无系统网络绕行入口。
    private var testEndpoint: URL? {
        #if DEBUG && targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--remote-integration-test"),
              let value = ProcessInfo.processInfo.environment["WEQ_REMOTE_TEST_ENDPOINT"],
              let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1",
              url.port != nil, url.path.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
        #else
        return nil
        #endif
    }

    var testMode: Bool { testEndpoint != nil }

    func pair() async {
        if rememberedComputer {
            await updateConnection()
            return
        }
        preparePairing()
        guard !busy, polling == nil else { return }
        failure = nil
        busy = true
        let generation = revision
        defer { if generation == revision { busy = false } }
        do {
            let invitation = try PairingInvitation(invitationText)
            invitationText = ""
            if invitation.fingerprint != nil && !invitation.isMultiRoute { await network.stop() }
            if let authKey = invitation.authKey, !invitation.isMultiRoute {
                guard !testMode, let expiresAt = invitation.expiresAt else { throw RemoteError.enrollment }
                invitationText = ""
                message = "正在入网"
                try await network.enroll(authKey: authKey, expiresAt: expiresAt)
                guard generation == revision else { throw CancellationError() }
            }
            let selection: RemoteSelection
            if let testEndpoint { selection = RemoteSelection(api: RemoteAPI(endpoint: testEndpoint, session: URLSession(configuration: EmbeddedNetwork.configuration(), delegate: NoRedirectDelegate(), delegateQueue: nil), deviceInfo: deviceInfo), status: nil, latencyMillis: nil) }
            else { selection = try await selectConnection(invitation.endpoints, pin: invitation.fingerprint, probe: invitation.isMultiRoute ? .hello : .none, invitation: invitation) }
            let newAPI = selection.api
            let session = newAPI.session
            let token = try DeviceCredential()
            let claim: PairClaim
            do {
                claim = try await newAPI.request("v1/pair", method: "POST", body: [
                    "invitation": invitation.secret, "name": "WeQ Remote iOS", "tokenHash": token.hash, "scope": "web:access",
                ])
            } catch { session.invalidateAndCancel(); throw error }
            guard generation == revision else { session.invalidateAndCancel(); return }
            guard claim.code.count == 6, claim.code.allSatisfy(\.isNumber),
                  claim.expiresAt > Date().timeIntervalSince1970 * 1000,
                  claim.expiresAt <= (Date().timeIntervalSince1970 + 180) * 1000 else {
                session.invalidateAndCancel()
                throw RemoteError.response
            }
            api?.session.invalidateAndCancel()
            api = newAPI
            credential = token
            fingerprint = newAPI.endpoint.scheme == "https" ? invitation.fingerprint : nil
            endpoints = invitation.isMultiRoute ? invitation.endpoints : nil
            routeFingerprint = invitation.isMultiRoute ? invitation.fingerprint : nil
            computerAddress = newAPI.endpoint.host
            invitationText = ""
            code = claim.code
            connected = false
            latency = nil
            checkedAt = nil
            message = "等待电脑确认"
            polling = Task { [weak self] in await self?.waitForApproval(claim, generation: generation) }
        } catch is CancellationError {} catch {
            if generation == revision { failure = .init(kind: .pairing, detail: error.localizedDescription) }
        }
    }

    private func updateConnection() async {
        guard !busy, polling == nil else { return }
        let text = invitationText
        disconnect()
        busy = true
        message = "正在更新连接"
        let generation = revision
        defer { if generation == revision { busy = false } }
        do {
            guard let saved = try SavedConnection.load() else { throw RemoteError.credential }
            let invitation = try PairingInvitation(text)
            // 更新连接时明确应用新 Key，即使随后局域网入口先响应也保留新入网身份。
            if let key = invitation.authKey, let expiry = invitation.expiresAt {
                try await network.enroll(authKey: key, expiresAt: expiry)
            }
            guard generation == revision else { throw CancellationError() }
            let selection = try await selectConnection(invitation.endpoints, pin: invitation.fingerprint,
                                                     probe: .status, token: saved.token)
            var adopted = false
            defer { if !adopted { selection.api.session.invalidateAndCancel() } }
            guard generation == revision else { throw CancellationError() }
            let updated = try saved.updatingRoutes(from: invitation, selected: selection.api.endpoint)
            try updated.save()
            api = selection.api
            adopted = true
            credential = try DeviceCredential(token: updated.token)
            endpoints = updated.endpoints
            routeFingerprint = updated.routeFingerprint
            fingerprint = updated.fingerprint
            computerAddress = updated.endpoint.host
            paired = true
            reconnectPaused = false
            await refresh(verified: selection)
        } catch is CancellationError {} catch {
            if generation == revision {
                if case RemoteError.unauthorized = error {
                    failure = .init(kind: .verification, detail: "新入口未接受现有授权，原连接已保留。")
                } else { showConnectionFailure(error) }
            }
        }
    }

    private func waitForApproval(_ claim: PairClaim, generation: Int) async {
        defer { if generation == revision { polling = nil } }
        do {
            _ = try await waitForRemoteApproval(claim, recover: {
                guard generation == self.revision else { throw CancellationError() }
                guard let endpoints = self.endpoints else { return }
                // 未批准的设备不能请求 status；仅用 hello 找到可达路径。
                let replacement = try await self.selectConnection(endpoints, pin: self.routeFingerprint, probe: .hello)
                guard generation == self.revision else { replacement.api.session.invalidateAndCancel(); throw CancellationError() }
                self.api?.session.invalidateAndCancel()
                self.api = replacement.api
                self.fingerprint = replacement.api.endpoint.scheme == "https" ? self.routeFingerprint : nil
                self.computerAddress = replacement.api.endpoint.host
            }, read: {
                guard generation == self.revision, let api = self.api, let credential = self.credential else { throw CancellationError() }
                return try await api.request("v1/pair/\(claim.id.uuidString.lowercased())", token: credential.token, timeout: 3)
            })
            guard generation == revision, let api, let credential else { return }
            if !testMode && (EmbeddedNetwork.integrationControl == nil || ProcessInfo.processInfo.arguments.contains("--remote-keep-credential")) { try SavedConnection(endpoint: api.endpoint, token: credential.token, fingerprint: fingerprint, endpoints: endpoints, routeFingerprint: routeFingerprint).save() }
            paired = true
            rememberedComputer = !testMode
            reconnectPaused = false
            code = nil
            await refresh()
        } catch is CancellationError {} catch {
            if generation == revision {
                disconnect()
                failure = .init(kind: .pairing, detail: error.localizedDescription)
            }
        }
    }

    func refresh() async {
        guard !busy else { return }
        await refresh(verified: nil)
    }

    private func prepareWeb(api: RemoteAPI, token: String, pin: String?, release: String, generation: Int) async throws {
        guard !testMode, failure?.kind.retriesWeb != true else { return }
        if webSession != nil {
            // A route failure must not discard a locally usable document.
            try await network.attachWeb(endpoint: api.endpoint, token: token, fingerprint: pin, release: release)
            return
        }
        do {
            if let session = try await network.webSession(token: token, endpoint: api.endpoint, fingerprint: pin, release: release) {
                guard generation == revision, !Task.isCancelled else {
                    session.close()
                    network.closeWeb()
                    throw CancellationError()
                }
                adoptWebSession(session)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw RemoteWebStartupError.load(error) }
    }

    // verified 为选路阶段已完成的鉴权状态读取；同一条入口直接沿用，避免连接时重复核验。
    private func refresh(verified: RemoteSelection?) async {
        if webReady, verified == nil { await refreshLiveConnection(); return }
        guard let api, let credential else { return }
        let generation = revision
        busy = true
        defer { if generation == revision { busy = false } }
        do {
            if api.endpoint.scheme == "http" { await network.refresh() }
            let requestMillis: Int
            let status: ComputerStatus
            if let verified, verified.api.endpoint == api.endpoint, let value = verified.status, let probed = verified.latencyMillis {
                status = value
                requestMillis = probed
            } else {
                let start = ContinuousClock.now
                let value: ComputerStatus = try await api.request("v1/status", token: credential.token)
                try value.validate()
                status = value
                requestMillis = elapsedMillis(ContinuousClock.now - start)
            }
            guard generation == revision, !Task.isCancelled else { return }
            checkedAt = Date()
            try await prepareWeb(api: api, token: credential.token, pin: fingerprint, release: status.webRelease ?? "", generation: generation)
            guard generation == revision, failure?.kind.retriesWeb != true else { return }
            latency = requestMillis
            health.succeeded(at: Date(), latency: requestMillis)
            scheduleConnectionWarning()
            connected = true
            code = nil
            message = "电脑在线"
            failure = nil
        } catch is CancellationError {} catch {
            if generation == revision, !Task.isCancelled {
                connectionFailed()
                let routeError = (error as? RemoteWebStartupError)?.loadCause ?? error
                if let endpoints, remoteRouteCanRetry(routeError) {
                    do {
                        let replacement = try await selectConnection(endpoints, pin: routeFingerprint, probe: .status, token: credential.token)
                        var adopted = false
                        defer { if !adopted { replacement.api.session.invalidateAndCancel() } }
                        guard generation == revision else { replacement.api.session.invalidateAndCancel(); return }
                        let pin = replacement.api.endpoint.scheme == "https" ? routeFingerprint : nil
                        checkedAt = Date()
                        try await prepareWeb(api: replacement.api, token: credential.token, pin: pin, release: replacement.status?.webRelease ?? "", generation: generation)
                        guard generation == revision, failure?.kind.retriesWeb != true else { return }
                        api.session.invalidateAndCancel(); self.api = replacement.api
                        adopted = true
                        fingerprint = pin; computerAddress = replacement.api.endpoint.host
                        latency = replacement.latencyMillis; connected = true; message = "电脑在线"; failure = nil
                        health.succeeded(at: Date(), latency: replacement.latencyMillis)
                        scheduleConnectionWarning()
                        return
                    } catch { if generation == revision, !Task.isCancelled { fail(error) } }
                } else { fail(error) }
            }
        }
    }

    private func refreshLiveConnection() async {
        guard let api, let credential, !busy else { return }
        let generation = revision
        let timeout = health.requestTimeout
        let epoch = healthEpoch
        let recover = health.failedChecks > 0
        health.beginCheck()
        scheduleConnectionWarning()
        busy = true
        defer { if generation == revision { busy = false } }
        do {
            let selection: RemoteSelection = try await withRemoteTimeout(timeout, discard: { (selection: RemoteSelection) in
                if selection.api.session !== api.session { selection.api.session.invalidateAndCancel() }
            }) { [self] in
                if recover {
                    return try await selectConnection(endpoints ?? [api.endpoint], pin: routeFingerprint ?? fingerprint, probe: .status, token: credential.token, timeout: timeout)
                }
                let start = ContinuousClock.now
                let value: ComputerStatus = try await api.request("v1/status", token: credential.token, timeout: timeout)
                try value.validate()
                return RemoteSelection(api: api, status: value, latencyMillis: elapsedMillis(ContinuousClock.now - start))
            }
            var adopted = selection.api.session === api.session
            defer { if !adopted { selection.api.session.invalidateAndCancel() } }
            guard generation == revision, epoch == healthEpoch, !Task.isCancelled else {
                if selection.api.session !== api.session { selection.api.session.invalidateAndCancel() }
                return
            }
            let pin = selection.api.endpoint.scheme == "https" ? routeFingerprint ?? fingerprint : nil
            if !testMode {
                try await network.attachWeb(endpoint: selection.api.endpoint, token: credential.token, fingerprint: pin, release: selection.status?.webRelease ?? "")
            }
            if selection.api.session !== api.session {
                api.session.invalidateAndCancel()
                self.api = selection.api
                adopted = true
                fingerprint = pin
                computerAddress = selection.api.endpoint.host
            }
            latency = selection.latencyMillis
            checkedAt = Date()
            if health.warning != nil { connectionRecovery += 1 }
            health.succeeded(at: Date(), latency: latency)
            publishConnectionHealth()
            scheduleConnectionWarning()
            connected = true
            message = "电脑在线"
            failure = nil
        } catch {
            guard generation == revision, epoch == healthEpoch, !Task.isCancelled else { return }
            if case RemoteError.unauthorized = error { fail(error); return }
            health.checkFailed()
            scheduleConnectionWarning()
            connected = false
            showConnectionFailure(error)
        }
    }

    private func showConnectionFailure(_ error: Error) {
        if case RemoteError.http(let code) = error {
            failure = .init(kind: .verification, detail: "电脑返回 HTTP \(code)。")
        } else if remoteRouteCanRetry(error) {
            failure = .init(kind: .connection, detail: "请确认电脑上的 WeQ 正在运行，且手机能访问电脑。")
        } else {
            failure = .init(kind: .verification, detail: error.localizedDescription)
        }
    }

    private func fail(_ error: Error) {
        connectionFailed()
        connected = false
        if case RemoteError.unauthorized = error {
            forget()
            failure = .init(kind: .authorization, detail: error.localizedDescription)
        } else if error is RemoteWebStartupError {
            failWebLoad(error)
        } else if failure?.kind.retriesWeb != true {
            showConnectionFailure(error)
        }
        message = failure?.kind.title ?? "连接失败"
    }

    func disconnect() {
        checkingWebReload = false
        webReloadFailed = false
        healthEpoch += 1
        connectionRecovery = 0
        eventCheck?.cancel()
        eventCheck = nil
        eventCheckID = nil
        lastEventCheck = nil
        healthDeadline?.cancel()
        healthDeadline = nil
        health = ConnectionHealth()
        webDownload = nil
        webDevelopmentProgress = nil
        reconnectPaused = true
        for session in probingSessions.values { session.invalidateAndCancel() }
        probingSessions.removeAll()
        webReady = false
        webMenuReady = false
        openingCachedWeb = false
        webSession?.close()
        network.closeWeb()
        webSession = nil
        revision += 1
        polling?.cancel()
        polling = nil
        api?.session.invalidateAndCancel()
        api = nil
        credential = nil
        endpoints = nil
        routeFingerprint = nil
        fingerprint = nil
        connected = false
        paired = false
        busy = false
        code = nil
        latency = nil
        checkedAt = nil
        computerAddress = nil
        message = "未配对"
        failure = nil
        invitationText = ""
    }
}
