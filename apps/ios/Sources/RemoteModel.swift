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
    let network: EmbeddedNetwork
    private var api: RemoteAPI?
    private var credential: DeviceCredential?
    private var polling: Task<Void, Never>?
    private var revision = 0
    private var fingerprint: String?
    private var reconnectPaused = false

    func resumeReconnect() { reconnectPaused = false }

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
        guard !reconnectPaused, !busy, polling == nil, api == nil else { return }
        let generation = revision
        busy = true
        defer { if generation == revision { busy = false } }
        do {
            guard let saved = try SavedConnection.load() else { return }
            message = "正在连接电脑"
            fingerprint = saved.fingerprint
            let session = try await connectionSession(endpoint: saved.endpoint, fingerprint: saved.fingerprint)
            guard generation == revision else { session.invalidateAndCancel(); return }
            api = RemoteAPI(endpoint: saved.endpoint, session: session)
            credential = try DeviceCredential(token: saved.token)
            computerAddress = saved.endpoint.host
            paired = true
            await refresh()
            if connected {
                let session = try await network.webSession(endpoint: saved.endpoint, token: saved.token, fingerprint: saved.fingerprint)
                guard generation == revision else { session.close(); return }
                webSession = session
            }
            else { api?.session.invalidateAndCancel(); api = nil }
        } catch { if generation == revision { api?.session.invalidateAndCancel(); api = nil; self.error = error.localizedDescription } }
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

    func forget() { SavedConnection.delete(); network.webDataStore.clear(); disconnect() }

    init(network: EmbeddedNetwork) { self.network = network }

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
            if invitation.fingerprint != nil { await network.stop() }
            if let authKey = invitation.authKey {
                guard !testMode, let expiresAt = invitation.expiresAt else { throw RemoteError.enrollment }
                invitationText = ""
                message = "正在入网"
                try await network.enroll(authKey: authKey, expiresAt: expiresAt)
                guard generation == revision else { throw CancellationError() }
            }
            let endpoint = testEndpoint ?? invitation.endpoint
            let session: URLSession
            if testMode { session = URLSession(configuration: EmbeddedNetwork.configuration(), delegate: NoRedirectDelegate(), delegateQueue: nil) }
            else { session = try await connectionSession(endpoint: endpoint, fingerprint: invitation.fingerprint) }
            let newAPI = RemoteAPI(endpoint: endpoint, session: session)
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
            fingerprint = invitation.fingerprint
            computerAddress = invitation.endpoint.host
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
                    if !testMode && (EmbeddedNetwork.integrationControl == nil || ProcessInfo.processInfo.arguments.contains("--remote-keep-credential")) { try SavedConnection(endpoint: api.endpoint, token: credential.token, fingerprint: fingerprint).save() }
                    paired = true
                    code = nil
                    await refresh()
                    if connected, !testMode {
                        let session = try await network.webSession(endpoint: api.endpoint, token: credential.token, fingerprint: fingerprint)
                        guard generation == revision else { session.close(); return }
                        webSession = session
                    }
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
            let duration = (ContinuousClock.now - start).components
            latency = Int(duration.seconds) * 1000 + Int(duration.attoseconds / 1_000_000_000_000_000)
            checkedAt = Date()
            connected = true
            code = nil
            message = "电脑在线"
            error = nil
        } catch is CancellationError {} catch {
            if generation == revision { fail(error) }
        }
    }

    private func fail(_ failure: Error) {
        connected = false
        message = "连接未通过"
        error = failure.localizedDescription
        if case RemoteError.unauthorized = failure { SavedConnection.delete(); network.webDataStore.clear(); disconnect(); error = failure.localizedDescription }
    }

    func disconnect() {
        webSession?.close()
        webSession = nil
        revision += 1
        polling?.cancel()
        polling = nil
        api?.session.invalidateAndCancel()
        api = nil
        credential = nil
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
