import CryptoKit
import Foundation
import Security

enum RemoteError: LocalizedError {
    case invitation, network, credential, expired, enrollment, unauthorized, response, http(Int)

    var errorDescription: String? {
        switch self {
        case .invitation: return "配对链接无效，请重新扫描电脑上的二维码。"
        case .network: return "无法连接电脑，请检查电脑是否在线及网络是否可达。"
        case .credential: return "无法生成安全的设备凭据。"
        case .expired: return "电脑确认已超时，请重新生成配对码。"
        case .enrollment: return "入网未完成，请检查 Key 是否已使用、过期或需要管理员批准，再重新生成邀请。"
        case .unauthorized: return "设备未授权或授权已被撤销，请重新配对。"
        case .response: return "电脑返回了不兼容的数据。"
        case .http(let code): return "电脑返回 HTTP \(code)，请检查邀请是否有效。"
        }
    }
}

struct PairingInvitation: Equatable {
    let endpoint: URL
    let secret: String
    let authKey: String?
    let expiresAt: Double?
    let fingerprint: String?

    init(_ text: String) throws {
        guard text.utf8.count <= 2048,
              let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "weq-remote", components.host == "pair",
              components.user == nil, components.password == nil, components.port == nil,
              components.path.isEmpty, components.fragment == nil,
              let items = components.queryItems,
              Set(items.map(\.name)).count == items.count,
              let rawEndpoint = items.first(where: { $0.name == "endpoint" })?.value,
              let endpoint = URL(string: rawEndpoint),
              let secret = items.first(where: { $0.name == "invitation" })?.value,
              secret.count == 64, secret.allSatisfy({ "0123456789abcdef".contains($0) })
        else { throw RemoteError.invitation }
        self.endpoint = endpoint
        self.secret = secret
        let version = items.first(where: { $0.name == "v" })?.value
        if version == "3", Set(items.map(\.name)) == Set(["v", "endpoint", "invitation", "fingerprint"]),
           Self.isDirectEndpoint(endpoint), let pin = items.first(where: { $0.name == "fingerprint" })?.value,
           pin.range(of: "\\A[a-f0-9]{64}\\z", options: .regularExpression) != nil {
            fingerprint = pin; authKey = nil; expiresAt = nil
        } else if version == "1", Self.isTailnetEndpoint(endpoint), Set(items.map(\.name)) == Set(["v", "endpoint", "invitation"]) {
            authKey = nil; expiresAt = nil; fingerprint = nil
        } else if version == "2", Set(items.map(\.name)) == Set(["v", "endpoint", "invitation", "authKey", "expiresAt"]),
                  Self.isTailnetEndpoint(endpoint),
                  let key = items.first(where: { $0.name == "authKey" })?.value, Self.validAuthKey(key),
                  let expiryText = items.first(where: { $0.name == "expiresAt" })?.value,
                  expiryText.range(of: "^[0-9]{13}$", options: .regularExpression) != nil,
                  let expiry = Double(expiryText), expiry > Date().timeIntervalSince1970 * 1000,
                  expiry <= (Date().timeIntervalSince1970 + 180) * 1000 {
            authKey = key; expiresAt = expiry; fingerprint = nil
        } else { throw RemoteError.invitation }
    }

    static func validAuthKey(_ key: String) -> Bool {
        key.range(of: "\\Atskey-auth-[A-Za-z0-9_-]{20,200}\\z", options: .regularExpression) != nil
    }

    static func isDirectEndpoint(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.path.isEmpty,
              url.query == nil, url.fragment == nil, let port = url.port, (1...65535).contains(port),
              let host = url.host else { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            guard let value = Int(part) else { return false }; return (0...255).contains(value) && String(value) == part
        }), let a = Int(parts[0]), let b = Int(parts[1]) else { return false }
        return a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 100 && (64...127).contains(b))
    }

    static func isTailnetEndpoint(_ url: URL) -> Bool {
        guard url.scheme == "http", url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil,
              let port = url.port, (1...65535).contains(port), let host = url.host else { return false }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            guard let number = Int(part) else { return false }
            return String(number) == part
        }),
              let a = Int(parts[0]), let b = Int(parts[1]), let c = Int(parts[2]), let d = Int(parts[3]) else { return false }
        return a == 100 && (64...127).contains(b) && (0...255).contains(c) && (0...255).contains(d)
    }
}

struct DeviceCredential {
    let token: String
    var hash: String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }

    init() throws {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RemoteError.credential }
        token = bytes.map { String(format: "%02x", $0) }.joined()
    }

    init(token: String) throws {
        guard token.range(of: "\\A[a-f0-9]{64}\\z", options: .regularExpression) != nil else { throw RemoteError.credential }
        self.token = token
    }
}

struct SavedConnection: Codable {
    let endpoint: URL
    let token: String
    let fingerprint: String?

    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "io.github.weqdevs.remote.connection", kSecAttrAccount as String: "computer"] }
    static func load() throws -> SavedConnection? {
        var query = query; query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw RemoteError.credential }
        let saved = try JSONDecoder().decode(Self.self, from: data)
        _ = try DeviceCredential(token: saved.token)
        guard saved.fingerprint == nil ? PairingInvitation.isTailnetEndpoint(saved.endpoint) :
                PairingInvitation.isDirectEndpoint(saved.endpoint) && saved.fingerprint?.range(of: "\\A[a-f0-9]{64}\\z", options: .regularExpression) != nil else { throw RemoteError.credential }
        return saved
    }
    func save() throws {
        let data = try JSONEncoder().encode(self)
        let status = SecItemUpdate(Self.query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = Self.query; query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw RemoteError.credential }
        } else if status != errSecSuccess { throw RemoteError.credential }
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

struct PairClaim: Decodable {
    let id: UUID
    let code: String
    let expiresAt: Double
}

struct PairApproval: Decodable {
    let id: UUID
    let approved: Bool
    let scope: String
}

struct ComputerStatus: Decodable {
    let product: String
    let `protocol`: Int
    let scope: String
    let online: Bool

    func validate() throws {
        guard product == "WeQ Remote", self.protocol == 1, scope == "status:read", online else { throw RemoteError.response }
    }
}

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let endpoint: URL?
    let fingerprint: String?
    init(endpoint: URL? = nil, fingerprint: String? = nil) { self.endpoint = endpoint; self.fingerprint = fingerprint }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard fingerprint != nil else { completionHandler(.performDefaultHandling, nil); return }
        if let credential = pinnedCredential(challenge, endpoint: endpoint, fingerprint: fingerprint) { completionHandler(.useCredential, credential) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

func pinnedCredential(_ challenge: URLAuthenticationChallenge, endpoint: URL?, fingerprint: String?) -> URLCredential? {
    guard let endpoint, let fingerprint, challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          challenge.protectionSpace.host == endpoint.host, challenge.protectionSpace.port == endpoint.port,
          let trust = challenge.protectionSpace.serverTrust,
          let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let certificate = certificates.first else { return nil }
    let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02x", $0) }.joined()
    return digest == fingerprint ? URLCredential(trust: trust) : nil
}

struct RemoteAPI {
    let endpoint: URL
    let session: URLSession

    func request<T: Decodable>(_ path: String, method: String = "GET", token: String? = nil,
                               body: [String: String]? = nil) async throws -> T {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (bytes, response) = try await session.bytes(for: request, delegate: session.delegate as? URLSessionTaskDelegate)
        guard let response = response as? HTTPURLResponse else { throw RemoteError.response }
        if response.statusCode == 401 { throw RemoteError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw RemoteError.http(response.statusCode) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65536 else { throw RemoteError.response }
            data.append(byte)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
