import XCTest
@testable import WeQRemote

final class RemoteProtocolTests: XCTestCase {
    func testWebResourcesAreBoundToExactOriginIncludingBlobURLs() {
        let endpoint = URL(string: "https://192.168.1.8:7691")!
        for value in ["https://192.168.1.8:7691/_download/id", "blob:https://192.168.1.8:7691/id"] {
            XCTAssertTrue(RemoteWebPolicy.resource(URL(string: value)!, endpoint: endpoint))
        }
        for value in ["http://192.168.1.8:7691/file", "https://192.168.1.8:7692/file", "https://secret@192.168.1.8:7691/file", "blob:https://192.168.1.8:76910/id", "data:text/html,test", "file:///private/file"] {
            XCTAssertFalse(RemoteWebPolicy.resource(URL(string: value)!, endpoint: endpoint))
        }
        XCTAssertTrue(RemoteWebPolicy.sameOrigin(URL(string: "https://example.com:443/path")!, endpoint: URL(string: "https://example.com")!))
    }

    func testExternalWebLinksDoNotAllowExecutableSchemesOrCredentials() {
        for value in ["https://example.com", "mailto:test@example.com", "mqqapi://example"] {
            XCTAssertTrue(RemoteWebPolicy.external(URL(string: value)!))
        }
        for value in ["javascript:alert(1)", "data:text/html,test", "file:///private/file", "https://secret@example.com", "intent://host"] {
            XCTAssertFalse(RemoteWebPolicy.external(URL(string: value)!))
        }
    }
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

    func testFastRouteDoesNotWaitForBlackholedFirstAddress() async throws {
        let slow = URL(string: "https://192.168.1.8:7691")!
        let fast = URL(string: "https://100.64.0.10:7692")!
        let start = ContinuousClock.now
        let (selected, _) = try await selectRemoteRoute([slow, fast]) { endpoint in
            if endpoint == slow {
                try await Task.sleep(for: .seconds(2))
                throw URLError(.timedOut)
            }
            return "reachable"
        }
        XCTAssertEqual(selected, fast)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testDirectRouteDoesNotWaitForEmbeddedEnrollment() async throws {
        let embedded = URL(string: "http://100.64.0.10:7691")!
        let direct = URL(string: "https://192.168.1.8:7691")!
        let start = ContinuousClock.now
        let (selected, _) = try await selectRemoteRoute([embedded, direct]) { endpoint in
            if endpoint == embedded { try await Task.sleep(for: .seconds(45)) }
            return "reachable"
        }
        XCTAssertEqual(selected, direct)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    @MainActor
    func testLosingSuccessfulProbeIsDisposed() async throws {
        let first = URL(string: "https://192.168.1.8:7691")!
        let second = URL(string: "https://100.64.0.10:7692")!
        var discarded: [URL] = []
        let (selected, _) = try await selectRemoteRoute([first, second], discard: { discarded.append($0) }) { endpoint in
            if endpoint == first {
                // 模拟底层 API 完成时恰好遇到取消，仍返回一个已创建的对象。
                try? await Task.sleep(for: .seconds(45))
            }
            return endpoint
        }
        XCTAssertEqual(selected, second)
        XCTAssertEqual(discarded, [first])
    }

    @MainActor
    func testApprovalTimeoutRecoversWithoutDiscardingClaim() async throws {
        let claim = PairClaim(id: UUID(), code: "123456", expiresAt: 10_000)
        var reads = 0, recoveries = 0
        let approval = try await waitForRemoteApproval(claim, now: { 0 }, pause: {}, recover: {
            recoveries += 1
        }, read: {
            reads += 1
            if reads == 1 { throw URLError(.timedOut) }
            return PairApproval(id: claim.id, approved: true, scope: "web:access")
        })
        XCTAssertTrue(approval.approved)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(recoveries, 1)
    }

    @MainActor
    func testApprovalStopsOnExpiryRejectionAndCancellation() async throws {
        let claim = PairClaim(id: UUID(), code: "123456", expiresAt: 2)
        var clock = 0.0, reads = 0
        do {
            _ = try await waitForRemoteApproval(claim, now: { clock }, pause: { clock += 1 }, recover: {}, read: {
                reads += 1
                throw URLError(.timedOut)
            })
            XCTFail("expired claim accepted")
        } catch RemoteError.expired {} catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(reads, 2)
        let failures: [Error] = [RemoteError.unauthorized, RemoteError.response, CancellationError()]
        for failure in failures {
            var recovered = false
            do {
                _ = try await waitForRemoteApproval(claim, now: { 0 }, pause: {}, recover: { recovered = true }, read: { throw failure })
                XCTFail("rejection swallowed")
            } catch { XCTAssertFalse(recovered) }
        }
    }

    @MainActor
    func testApprovalDoesNotAcceptAnotherClaimOrScope() async throws {
        let claim = PairClaim(id: UUID(), code: "123456", expiresAt: 10_000)
        for approval in [PairApproval(id: UUID(), approved: true, scope: "web:access"),
                         PairApproval(id: claim.id, approved: true, scope: "status:read")] {
            do {
                _ = try await waitForRemoteApproval(claim, now: { 0 }, pause: {}, recover: { XCTFail("invalid response triggered recovery") }, read: { approval })
                XCTFail("invalid approval accepted")
            } catch RemoteError.response {} catch { XCTFail("unexpected error: \(error)") }
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
