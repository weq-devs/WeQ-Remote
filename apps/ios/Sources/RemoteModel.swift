import Combine
import Foundation

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
    @Published private(set) var error: String?
    @Published private(set) var webSession: RemoteWebSession?
    @Published private(set) var rememberedComputer = false
    let network: EmbeddedNetwork
    private var api: RemoteAPI?
    private var credential: DeviceCredential?
    private var polling: Task<Void, Never>?
    private var revision = 0
    private var fingerprint: String?
    private var endpoints: [URL]?
    private var routeFingerprint: String?
    private var reconnectPaused = false

    func resumeReconnect() { reconnectPaused = false }

    func suspend() {
        // 已配对的网页与节点留在内存；前台恢复只验证，不重建页面。
        guard webSession == nil else { return }
        disconnect()
        resumeReconnect()
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

    func reconnect() async {
        guard !reconnectPaused, !busy, polling == nil else { return }
        if api != nil { await refresh(); return }
        let generation = revision
        busy = true
        defer { if generation == revision { busy = false } }
        do {
            guard let saved = try SavedConnection.load() else { rememberedComputer = false; return }
            rememberedComputer = true
            message = "正在连接电脑"
            let connection = try await selectConnection(saved.endpoints ?? [saved.endpoint], pin: saved.routeFingerprint ?? saved.fingerprint, probe: saved.endpoints != nil, token: saved.token)
            guard generation == revision else { connection.session.invalidateAndCancel(); return }
            endpoints = saved.endpoints; routeFingerprint = saved.routeFingerprint
            fingerprint = connection.endpoint.scheme == "https" ? saved.routeFingerprint ?? saved.fingerprint : nil
            api = connection
            credential = try DeviceCredential(token: saved.token)
            computerAddress = connection.endpoint.host
            paired = true
            await refresh()
            if !connected { api?.session.invalidateAndCancel(); api = nil }
        } catch {
            if generation == revision, !Task.isCancelled {
                if case RemoteError.unauthorized = error { fail(error) }
                else { api?.session.invalidateAndCancel(); api = nil; self.error = error.localizedDescription }
            }
        }
    }

    private func connectionSession(endpoint: URL, fingerprint: String?) async throws -> URLSession {
        if let fingerprint {
            return URLSession(configuration: EmbeddedNetwork.configuration(), delegate: NoRedirectDelegate(endpoint: endpoint, fingerprint: fingerprint), delegateQueue: nil)
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
        return try await network.session()
    }

    private func selectConnection(_ endpoints: [URL], pin: String?, probe: Bool, token: String? = nil) async throws -> RemoteAPI {
        let generation = revision
        let (_, selected) = try await selectRemoteRoute(endpoints) { endpoint in
            let session = try await self.connectionSession(endpoint: endpoint, fingerprint: endpoint.scheme == "https" ? pin : nil)
            do {
                guard generation == self.revision else { throw CancellationError() }
                let api = RemoteAPI(endpoint: endpoint, session: session)
                if probe {
                    if let token {
                        let status: ComputerStatus = try await api.request("v1/status", token: token, timeout: 3)
                        try status.validate()
                    } else {
                        let hello: RemoteHello = try await api.request("v1/hello", timeout: 3)
                        try hello.validate()
                    }
                }
                guard generation == self.revision else { throw CancellationError() }
                return api
            } catch { session.invalidateAndCancel(); throw error }
        }
        return selected
    }

    func forget() { SavedConnection.delete(); rememberedComputer = false; network.webDataStore.clear(); disconnect() }

    init(network: EmbeddedNetwork) {
        self.network = network
        rememberedComputer = (try? SavedConnection.load()) != nil
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
        preparePairing()
        guard !busy, polling == nil else { return }
        error = nil
        busy = true
        let generation = revision
        defer { if generation == revision { busy = false } }
        do {
            let invitation = try PairingInvitation(invitationText)
            invitationText = ""
            if invitation.fingerprint != nil && !invitation.isMultiRoute { await network.stop() }
            if let authKey = invitation.authKey {
                guard !testMode, let expiresAt = invitation.expiresAt else { throw RemoteError.enrollment }
                invitationText = ""
                message = "正在入网"
                try await network.enroll(authKey: authKey, expiresAt: expiresAt)
                guard generation == revision else { throw CancellationError() }
            }
            let newAPI: RemoteAPI
            if let testEndpoint { newAPI = RemoteAPI(endpoint: testEndpoint, session: URLSession(configuration: EmbeddedNetwork.configuration(), delegate: NoRedirectDelegate(), delegateQueue: nil)) }
            else { newAPI = try await selectConnection(invitation.endpoints, pin: invitation.fingerprint, probe: invitation.isMultiRoute) }
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
            if generation == revision { self.error = error.localizedDescription }
        }
    }

    private func waitForApproval(_ claim: PairClaim, generation: Int) async {
        defer { if generation == revision { polling = nil } }
        do {
            while Date().timeIntervalSince1970 * 1000 < claim.expiresAt {
                try Task.checkCancellation()
                guard generation == revision, let api, let credential else { return }
                let approval: PairApproval = try await api.request("v1/pair/\(claim.id.uuidString.lowercased())", token: credential.token)
                guard generation == revision else { return }
                guard approval.id == claim.id, approval.scope == "web:access" else { throw RemoteError.response }
                if approval.approved {
                    if !testMode && (EmbeddedNetwork.integrationControl == nil || ProcessInfo.processInfo.arguments.contains("--remote-keep-credential")) { try SavedConnection(endpoint: api.endpoint, token: credential.token, fingerprint: fingerprint, endpoints: endpoints, routeFingerprint: routeFingerprint).save() }
                    paired = true
                    rememberedComputer = !testMode
                    reconnectPaused = false
                    code = nil
                    await refresh()
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            throw RemoteError.expired
        } catch is CancellationError {} catch {
            if generation == revision {
                disconnect()
                self.error = error.localizedDescription
            }
        }
    }

    func refresh() async {
        guard let api, let credential else { return }
        let generation = revision
        busy = true
        defer { if generation == revision { busy = false } }
        do {
            let start = ContinuousClock.now
            let status: ComputerStatus = try await api.request("v1/status", token: credential.token)
            try status.validate()
            guard generation == revision else { return }
            if webSession == nil, !testMode {
                let session = try await network.webSession(endpoint: api.endpoint, token: credential.token, fingerprint: fingerprint)
                guard generation == revision else { session.close(); return }
                webSession = session
            }
            let duration = (ContinuousClock.now - start).components
            latency = Int(duration.seconds) * 1000 + Int(duration.attoseconds / 1_000_000_000_000_000)
            checkedAt = Date()
            connected = true
            code = nil
            message = "电脑在线"
            error = nil
        } catch is CancellationError {} catch {
            if generation == revision, !Task.isCancelled {
                if let endpoints, remoteRouteCanRetry(error) {
                    do {
                        let replacement = try await selectConnection(endpoints, pin: routeFingerprint, probe: true, token: credential.token)
                        var adopted = false
                        defer { if !adopted { replacement.session.invalidateAndCancel() } }
                        guard generation == revision else { replacement.session.invalidateAndCancel(); return }
                        let pin = replacement.endpoint.scheme == "https" ? routeFingerprint : nil
                        let replaceWeb = webSession == nil || webSession?.endpoint != replacement.endpoint
                        let web = replaceWeb ? try await network.webSession(endpoint: replacement.endpoint, token: credential.token, fingerprint: pin) : nil
                        guard generation == revision else { web?.close(); replacement.session.invalidateAndCancel(); return }
                        api.session.invalidateAndCancel(); self.api = replacement
                        adopted = true
                        if let web { webSession?.close(); webSession = web }
                        fingerprint = pin; computerAddress = replacement.endpoint.host
                        connected = true; message = "电脑在线"; self.error = nil; checkedAt = Date()
                        return
                    } catch { if generation == revision, !Task.isCancelled { fail(error) } }
                } else { fail(error) }
            }
        }
    }

    private func fail(_ failure: Error) {
        connected = false
        message = "连接未通过"
        error = failure.localizedDescription
        if case RemoteError.unauthorized = failure { forget(); error = failure.localizedDescription }
    }

    func disconnect() {
        reconnectPaused = true
        webSession?.close()
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
        error = nil
        invitationText = ""
    }
}
