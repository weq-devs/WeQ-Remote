import XCTest

final class ConnectionUITests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:45198")!

    @MainActor
    func testRealDesktopProtocolAndRevocation() async throws {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("test/invitation"))
        let invitation = try JSONDecoder().decode(TestInvitation.self, from: data)
        let app = XCUIApplication()
        let (networkData, networkResponse) = try await URLSession.shared.data(from: base.appendingPathComponent("test/network"))
        let usesTS = (networkResponse as? HTTPURLResponse)?.statusCode == 200
        if usesTS {
            let network = try JSONDecoder().decode(TestNetwork.self, from: networkData)
            app.launchArguments = ["--remote-ts-integration-test"]
            app.launchEnvironment["WEQ_REMOTE_TEST_CONTROL"] = network.control
        } else {
            app.launchArguments = ["--remote-integration-test"]
            app.launchEnvironment["WEQ_REMOTE_TEST_ENDPOINT"] = base.absoluteString
        }
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "pairingLink").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(invitation.url)
        app.buttons["pairComputer"].tap()
        if usesTS {
            let web = app.webViews.firstMatch
            XCTAssertTrue(web.waitForExistence(timeout: 25))
            XCTAssertTrue(web.staticTexts["Web 已连接"].waitForExistence(timeout: 15))
            XCTAssertTrue(web.staticTexts["WebSocket 已连接"].waitForExistence(timeout: 15))
            web.buttons["验证网页请求"].tap()
            var revoke = URLRequest(url: base.appendingPathComponent("test/revoke"))
            revoke.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: revoke)
            XCTAssertTrue(web.staticTexts["订阅已断开"].waitForExistence(timeout: 15))
            XCTAssertTrue(web.staticTexts["授权已撤销"].waitForExistence(timeout: 15))
            app.terminate()
            return
        }
        XCTAssertTrue(app.buttons["verifyConnection"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["电脑在线"].exists)
        app.buttons["verifyConnection"].tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "WeQ Remote real HTTP connected"
        shot.lifetime = .keepAlways
        add(shot)

        var request = URLRequest(url: base.appendingPathComponent("test/revoke"))
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
        app.buttons["verifyConnection"].tap()
        let error = app.staticTexts["connectionError"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        XCTAssertTrue(error.label.contains("授权已被撤销"))
        XCTAssertFalse(app.buttons["verifyConnection"].exists)
        app.terminate()
    }

    @MainActor
    func testUnpairedAppOnlyShowsScanAndLinkInput() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["扫码"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "pairingLink").firstMatch.exists)
        XCTAssertFalse(app.buttons["连接网络"].exists)
        XCTAssertFalse(app.buttons["登录 Tailscale"].exists)
        XCTAssertFalse(app.buttons["pairComputer"].exists)
        app.terminate()
    }
}

private struct TestInvitation: Decodable { let url: String }
private struct TestNetwork: Decodable { let endpoint: String; let control: String }
