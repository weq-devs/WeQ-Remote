import XCTest
@testable import WeQRemote

final class RemoteProtocolTests: XCTestCase {
    private func link(endpoint: String = "http://100.64.0.10:7691", extra: String = "") -> String {
        "weq-remote://pair?v=1&endpoint=\(endpoint.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)&invitation=\(String(repeating: "a", count: 64))\(extra)"
    }

    func testAcceptsDesktopInvitation() throws {
        let invitation = try PairingInvitation(link())
        XCTAssertEqual(invitation.endpoint.host, "100.64.0.10")
        XCTAssertEqual(invitation.secret.count, 64)
    }

    func testSavedConnectionKeepsRequestURLAfterRelaunch() throws {
        for origin in ["http://100.64.0.10:7691", "https://192.168.1.8:7691"] {
            let saved = SavedConnection(endpoint: URL(string: origin)!, token: String(repeating: "a", count: 64), fingerprint: origin.hasPrefix("https") ? String(repeating: "f", count: 64) : nil)
            let restored = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(saved))
            XCTAssertEqual(restored.endpoint.absoluteString, origin)
            XCTAssertEqual(restored.endpoint.appendingPathComponent("v1/status").absoluteString, origin + "/v1/status")
            XCTAssertEqual(restored.fingerprint, saved.fingerprint)
            XCTAssertEqual(try DeviceCredential(token: restored.token).hash, try DeviceCredential(token: saved.token).hash)
        }
    }

    func testDirectInvitationPinsPrivateEndpoint() throws {
        let pin = String(repeating: "f", count: 64)
        let direct = link(endpoint: "https://192.168.1.8:7691").replacingOccurrences(of: "v=1", with: "v=3") + "&fingerprint=\(pin)"
        XCTAssertEqual(try PairingInvitation(direct).fingerprint, pin)
        for host in ["10.0.0.2", "172.16.1.2", "100.64.0.9"] {
            XCTAssertNoThrow(try PairingInvitation(direct.replacingOccurrences(of: "192.168.1.8", with: host)))
        }
        for invalid in [direct.replacingOccurrences(of: "https:", with: "http:"), direct.replacingOccurrences(of: pin, with: "bad"), direct.replacingOccurrences(of: "192.168.1.8", with: "8.8.8.8"), direct.replacingOccurrences(of: "192.168.1.8", with: "127.0.0.1"), direct + "&fingerprint=\(pin)"] { XCTAssertThrowsError(try PairingInvitation(invalid)) }
    }

    func testEnrollmentInvitation() throws {
        let key = "tskey-auth-" + String(repeating: "k", count: 40)
        let expiry = String(Int(Date().timeIntervalSince1970 * 1000) + 120000)
        let bootstrap = link().replacingOccurrences(of: "v=1", with: "v=2") + "&authKey=\(key)&expiresAt=\(expiry)"
        let invitation = try PairingInvitation(bootstrap)
        XCTAssertEqual(invitation.authKey, key)
        XCTAssertEqual(invitation.expiresAt, Double(expiry))
        for invalid in [bootstrap.replacingOccurrences(of: key, with: "tskey-api-invalid"),
                        bootstrap.replacingOccurrences(of: "v=2", with: "v=1"),
                        bootstrap + "&authKey=\(key)",
                        bootstrap.replacingOccurrences(of: expiry, with: "1000000000000"),
                        bootstrap.replacingOccurrences(of: expiry, with: "9999999999999"),
                        bootstrap.replacingOccurrences(of: "&authKey=\(key)", with: "&control=https://evil.invalid"),
                        bootstrap.replacingOccurrences(of: key, with: key + "%0A")] {
            XCTAssertThrowsError(try PairingInvitation(invalid))
        }
    }

    func testMultiRouteInvitation() throws {
        let pin = String(repeating: "f", count: 64)
        let multi = link(endpoint: "https://192.168.1.8:7691").replacingOccurrences(of: "v=1", with: "v=4") + "&fingerprint=\(pin)&endpoint=http://100.64.0.10:7691&endpoint=https://100.64.0.10:7692"
        XCTAssertEqual(try PairingInvitation(multi).endpoints.map(\.host), ["192.168.1.8", "100.64.0.10", "100.64.0.10"])
        let keyed = multi + "&authKey=tskey-auth-\(String(repeating: "k", count: 40))&expiresAt=\(Int(Date().timeIntervalSince1970 * 1000) + 120000)"
        XCTAssertNotNil(try PairingInvitation(keyed).authKey)
        for invalid in [multi + "&endpoint=https://192.168.1.8:7691", multi.replacingOccurrences(of: "100.64.0.10", with: "8.8.8.8"), multi.replacingOccurrences(of: "v=4", with: "v=3"), multi + "&unknown=x", multi + "&v=4"] {
            XCTAssertThrowsError(try PairingInvitation(invalid))
        }
    }

    func testSavedRoutesKeepAllEntrancesButNotEnrollmentKey() throws {
        let lan = URL(string: "https://192.168.1.8:7691")!, tailnet = URL(string: "http://100.64.0.10:7691")!
        let pin = String(repeating: "f", count: 64)
        let saved = SavedConnection(endpoint: tailnet, token: String(repeating: "a", count: 64), fingerprint: nil, endpoints: [lan, tailnet], routeFingerprint: pin)
        let restored = try JSONDecoder().decode(SavedConnection.self, from: JSONEncoder().encode(saved))
        try restored.validate()
        XCTAssertEqual(restored.endpoints, [lan, tailnet])
        XCTAssertEqual(restored.routeFingerprint, pin)
        XCTAssertThrowsError(try SavedConnection(endpoint: tailnet, token: saved.token, fingerprint: nil, endpoints: [lan], routeFingerprint: pin).validate())
    }

    func testRouteFailoverOnlyRetriesConnectionFailures() async throws {
        let lan = URL(string: "https://192.168.1.8:7691")!, tailnet = URL(string: "http://100.64.0.10:7691")!
        var visited: [URL] = []
        let (selected, _) = try await selectRemoteRoute([lan, tailnet]) { endpoint in
            visited.append(endpoint)
            if endpoint == lan { throw URLError(.cannotConnectToHost) }
            return "reachable"
        }
        XCTAssertEqual(visited, [lan, tailnet]); XCTAssertEqual(selected, tailnet)
        let rejections: [Error] = [RemoteError.unauthorized, RemoteError.response, CancellationError(), URLError(.serverCertificateUntrusted)]
        for rejection in rejections {
            visited = []
            do { _ = try await selectRemoteRoute([lan, tailnet]) { endpoint -> String in visited.append(endpoint); throw rejection }; XCTFail("rejection swallowed") }
            catch { XCTAssertEqual(visited, [lan]) }
        }
    }

    func testRejectsNonTailnetDestinations() {
        for endpoint in ["http://127.0.0.1:7691", "http://192.168.1.1:80", "http://100.128.0.1:7691",
                         "http://100.63.0.1:7691", "http://example.com:80", "http://100.64.0.1:7691/path",
                         "http://user@100.64.0.1:7691", "http://100.64.0.1:0", "http://100.64.999.1:7691"] {
            XCTAssertThrowsError(try PairingInvitation(link(endpoint: endpoint)), endpoint)
        }
    }

    func testRejectsDuplicateAndUnknownFields() {
        XCTAssertThrowsError(try PairingInvitation(link(extra: "&v=1")))
        XCTAssertThrowsError(try PairingInvitation(link(extra: "&unknown=1")))
        XCTAssertThrowsError(try PairingInvitation(link().replacingOccurrences(of: "v=1", with: "v=2")))
        XCTAssertThrowsError(try PairingInvitation("https://example.com"))
    }

    func testSecureCredentialMatchesDesktopHashConvention() throws {
        let a = try DeviceCredential(), b = try DeviceCredential()
        XCTAssertEqual(a.token.count, 64)
        XCTAssertEqual(a.hash.count, 64)
        XCTAssertNotEqual(a.token, b.token)
        XCTAssertNotEqual(a.hash, b.hash)
        XCTAssertTrue(a.token.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testRequiresCompatibleComputerStatus() throws {
        let valid = Data(#"{"product":"WeQ Remote","protocol":1,"scope":"status:read","online":true}"#.utf8)
        try JSONDecoder().decode(ComputerStatus.self, from: valid).validate()
        for field in [valid.replacingOccurrences(of: "WeQ Remote", with: "Other"),
                      valid.replacingOccurrences(of: "true", with: "false")] {
            XCTAssertThrowsError(try JSONDecoder().decode(ComputerStatus.self, from: field).validate())
        }
    }
}

private extension Data {
    func replacingOccurrences(of old: String, with new: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
    }
}
