#if DEBUG && targetEnvironment(simulator)
import Foundation
import WebKit

@MainActor
enum WebSmoke {
    static func run(model: RemoteModel, network: EmbeddedNetwork) async {
        let lan = ProcessInfo.processInfo.arguments.contains("--remote-lan-smoke-test")
        guard ProcessInfo.processInfo.arguments.contains("--remote-web-smoke-test"), lan || EmbeddedNetwork.integrationControl != nil else { return }
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("web-smoke.json")
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        func stage(_ value: String) { try? Data(value.utf8).write(to: output.deletingLastPathComponent().appendingPathComponent("web-smoke-stage.txt"), options: .atomic) }
        stage("started")
        do {
            let base = URL(string: "http://127.0.0.1:45198")!
            if ProcessInfo.processInfo.arguments.contains("--remote-reconnect-only") {
                model.resumeReconnect()
                await model.reconnect()
                stage("cold-reconnected")
                guard let session = model.webSession else { throw SmokeFailure.pairing }
                try await wait(session.view, contains: "Web 已连接")
                try await wait(session.view, contains: "WebSocket 已连接")
                let (countData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("test/devices"))
                let count = try JSONSerialization.jsonObject(with: countData) as? [String: Int]
                guard count?["count"] == 1 else { throw SmokeFailure.pairing }
                var revoke = URLRequest(url: base.appendingPathComponent("test/revoke")); revoke.httpMethod = "POST"
                _ = try await URLSession.shared.data(for: revoke)
                try await wait(session.view, contains: "授权已撤销")
                SavedConnection.delete()
                try JSONSerialization.data(withJSONObject: ["passed": true, "checks": ["cold launch from Keychain", "no new pairing", "HTTP + WebSocket", "revocation"]]).write(to: output, options: .atomic)
                return
            }
            if !lan {
            await network.start()
            for _ in 0..<60 {
                await network.refresh()
                if network.connected { break }
                try await Task.sleep(for: .seconds(1))
            }
            guard network.connected else { throw SmokeFailure.network }
            }
            let (data, _) = try await URLSession.shared.data(from: base.appendingPathComponent("test/invitation"))
            let invitation = try JSONDecoder().decode(Invitation.self, from: data)
            stage("invitation")
            if lan {
                let parsed = try PairingInvitation(invitation.url)
                guard let pin = parsed.fingerprint else { throw SmokeFailure.pairing }
                model.invitationText = invitation.url.replacingOccurrences(of: "fingerprint=\(pin)", with: "fingerprint=" + String(repeating: "0", count: 64))
                await model.pair()
                stage("wrong-pin-rejected")
                guard model.error != nil, !model.paired, model.webSession == nil else { throw SmokeFailure.certificate }
            }
            model.invitationText = invitation.url
            await model.pair()
            stage("pair-requested")
            for _ in 0..<40 {
                if model.webSession != nil { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            guard let session = model.webSession else { throw SmokeFailure.pairing }
            stage("web-created")
            try await wait(session.view, contains: "WebSocket 已连接")
            try await wait(session.view, contains: "Web 已连接")
            stage("web-connected")
            _ = try await session.view.evaluateJavaScript("window.__weqResumeMarker = 'retained'")
            model.suspend()
            await model.reconnect()
            guard model.webSession === session,
                  try await session.view.evaluateJavaScript("window.__weqResumeMarker") as? String == "retained" else { throw SmokeFailure.web }
            stage("session-retained")
            if lan {
                model.disconnect()
                model.resumeReconnect()
                await model.reconnect()
                stage("reconnected")
                guard let reconnected = model.webSession else { throw SmokeFailure.pairing }
                try await wait(reconnected.view, contains: "WebSocket 已连接")
            }
            guard let session = model.webSession else { throw SmokeFailure.pairing }
            _ = try await session.view.evaluateJavaScript("document.querySelector('#probe').click()")
            if ProcessInfo.processInfo.arguments.contains("--remote-keep-credential") {
                try JSONSerialization.data(withJSONObject: ["passed": true, "checks": ["first launch", "WebView session replacement", "saved credential"]]).write(to: output, options: .atomic)
                return
            }
            var revoke = URLRequest(url: base.appendingPathComponent("test/revoke")); revoke.httpMethod = "POST"
            _ = try await URLSession.shared.data(for: revoke)
            stage("revoked")
            try await wait(session.view, contains: "订阅已断开")
            try await wait(session.view, contains: "授权已撤销")
            if lan { SavedConnection.delete() }
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": [lan ? "LAN TLS pin + saved credential reconnect" : "embedded TS", "same session + DOM after suspend/resume", "WKWebView HTTP", "WebSocket", "revocation"]]).write(to: output, options: .atomic)
        } catch {
            if lan { SavedConnection.delete() }
            // 不把 SDK 错误描述、邀请或凭据写入测试文件。
            try? JSONSerialization.data(withJSONObject: ["passed": false, "stage": String(describing: error as? SmokeFailure ?? .web)]).write(to: output, options: .atomic)
        }
    }

    private static func wait(_ view: WKWebView, contains text: String) async throws {
        for _ in 0..<40 {
            if view.window == nil { try await Task.sleep(for: .milliseconds(500)); continue }
            if let body = try? await view.evaluateJavaScript("document.body.innerText") as? String, body.contains(text) { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw SmokeFailure.web
    }
    private struct Invitation: Decodable { let url: String }
    private enum SmokeFailure: Error { case network, pairing, web, certificate }
}
#endif
