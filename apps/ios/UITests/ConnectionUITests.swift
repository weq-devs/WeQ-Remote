import XCTest

final class ConnectionUITests: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:45198")!

    @MainActor
    func testConnectionDetailsAndPersistentPrereleasePreference() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleInterfaceStyle", "Light"]
        app.launch()
        XCTAssertTrue(app.buttons["connectionMenu"].waitForExistence(timeout: 15))
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "Remote home light"; home.lifetime = .keepAlways; add(home)
        app.buttons["connectionMenu"].tap()
        let toggle = app.switches["检查测试版"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["检查更新"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Tailscale：")).firstMatch.exists)
        let original = toggle.value as? String
        toggle.tap()
        let expected = toggle.value as? String
        XCTAssertNotEqual(original, expected)
        let details = XCTAttachment(screenshot: app.screenshot())
        details.name = "Remote connection details light"; details.lifetime = .keepAlways; add(details)
        app.terminate()
        app.launchArguments = ["-AppleInterfaceStyle", "Dark"]
        app.launch()
        XCTAssertTrue(app.buttons["connectionMenu"].waitForExistence(timeout: 15))
        let darkHome = XCTAttachment(screenshot: app.screenshot())
        darkHome.name = "Remote home dark"; darkHome.lifetime = .keepAlways; add(darkHome)
        app.buttons["connectionMenu"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, expected)
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, original)
        let darkDetails = XCTAttachment(screenshot: app.screenshot())
        darkDetails.name = "Remote connection details dark"; darkDetails.lifetime = .keepAlways; add(darkDetails)
        app.terminate()
    }

    @MainActor
    func testLANBackgroundResume() async throws {
        let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("test/invitation"))
        let invitation = try JSONDecoder().decode(TestInvitation.self, from: data)
        guard URLComponents(string: invitation.url)?.queryItems?.contains(where: { $0.name == "fingerprint" }) == true else {
            throw XCTSkip("未启动局域网 HTTPS 夹具")
        }
        let app = XCUIApplication()
        app.launch()
        let field = app.descendants(matching: .any).matching(identifier: "pairingLink").firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText(invitation.url)
            app.buttons["pairComputer"].tap()
        }
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 30))
        XCTAssertTrue(web.staticTexts["Web 已连接"].waitForExistence(timeout: 15))
        XCTAssertTrue(web.staticTexts["WebSocket 已连接"].waitForExistence(timeout: 15))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(web.staticTexts["Web 已连接"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["扫码"].exists)
        let (countData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("test/devices"))
        XCTAssertEqual(try JSONDecoder().decode(DeviceCount.self, from: countData).count, 1)
        var revoke = URLRequest(url: base.appendingPathComponent("test/revoke"))
        revoke.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: revoke)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        app.terminate()
    }

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
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(web.staticTexts["Web 已连接"].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["扫码"].exists)
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
private struct DeviceCount: Decodable { let count: Int }
