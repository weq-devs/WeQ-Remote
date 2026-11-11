import XCTest
@testable import WeQRemote

final class ReleaseVersionTests: XCTestCase {
    func testPrereleaseSwitchHonorsBothMetadataAndBetaVersionNames() throws {
        let data = Data("""
        [{"tag_name":"v1.0.0b2","draft":false,"prerelease":false,"published_at":"x","assets":[{"name":"SHA256SUMS"}]},
         {"tag_name":"v0.2.0","draft":false,"prerelease":false,"published_at":"x","assets":[{"name":"SHA256SUMS"}]},
         {"tag_name":"v1.1.0","draft":false,"prerelease":true,"published_at":"x","assets":[{"name":"SHA256SUMS"}]},
         {"tag_name":"v2.0.0","draft":true,"prerelease":false,"published_at":"x","assets":[{"name":"SHA256SUMS"}]}]
        """.utf8)
        XCTAssertEqual(try RemoteRelease.select(data, includePrerelease: false)?.version?.text, "0.2.0")
        XCTAssertEqual(try RemoteRelease.select(data, includePrerelease: true)?.version?.text, "1.1.0")
    }
    func testOrderingAndInvalidVersions() {
        let ordered = ["0.2.0", "1.0.0b2", "1.0.0b10", "1.0.0", "1.0.1b1", "1.10.0", "2.0.0"]
        for pair in zip(ordered, ordered.dropFirst()) { XCTAssertLessThan(ReleaseVersion(pair.0)!, ReleaseVersion(pair.1)!) }
        for text in ["1.0", "v1.0.0", "01.0.0", "1.0.0b0", "1.0.0\n", "1.0.0-rc.1", "999999999999999999999.0.0"] { XCTAssertNil(ReleaseVersion(text), text) }
    }
    func testManifestRejectsWrongPlatformAmbiguityAndInvalidContent() {
        let line = String(repeating: "a", count: 64) + "  weq-remote-1.0.0b10-ios-arm64-unsigned.ipa\n"
        XCTAssertEqual(ReleaseManifest(line, platform: "ios")?.version.text, "1.0.0b10")
        XCTAssertNil(ReleaseManifest(line, platform: "android"))
        XCTAssertNil(ReleaseManifest(line + line, platform: "ios"))
        XCTAssertNil(ReleaseManifest("<html>blocked</html>", platform: "ios"))
        XCTAssertNil(ReleaseManifest(line.replacingOccurrences(of: "1.0.0b10", with: "../../bad"), platform: "ios"))
    }
    func testMirrorsIgnoreStaleVersionsAndRankRealTransfers() async throws {
        let ranked = try await UpdateMirrors.resolve(prefixes: ["https://old.invalid/", "https://slow.invalid/", "https://fast.invalid/", "https://dead.invalid/"]) { url, range in
            if url.host == "dead.invalid" { throw URLError(.cannotConnectToHost) }
            if range {
                try await Task.sleep(for: .milliseconds(url.host == "slow.invalid" ? 100 : 10))
                return Data(repeating: 1, count: 262144)
            }
            let version = url.host == "old.invalid" ? "0.2.0" : "1.0.0b2"
            return Data((String(repeating: "a", count: 64) + "  weq-remote-\(version)-ios-arm64-unsigned.ipa\n").utf8)
        }
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.first?.prefix, "https://fast.invalid/")
        XCTAssertTrue(ranked.allSatisfy { $0.downloadURL.absoluteString.contains("/download/v1.0.0b2/") })
        do {
            _ = try await UpdateMirrors.resolve(prefixes: [""]) { _, _ in throw URLError(.notConnectedToInternet) }
            XCTFail("all failed must not become up-to-date")
        } catch { }
    }
}
