import XCTest
@testable import WeQRemote

final class RemoteNetworkCostTests: XCTestCase {
    func testCostDistinguishesUnknownMeteredAndConstrained() throws {
        XCTAssertEqual(RemoteNetworkCost.unknown.state, "unknown")
        XCTAssertFalse(RemoteNetworkCost(available: true, constrained: false, metered: false).restricted)
        XCTAssertTrue(RemoteNetworkCost(available: true, constrained: false, metered: true).restricted)
        let cost = RemoteNetworkCost(available: true, constrained: true, metered: false)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(cost.json.utf8)) as? [String: Any])
        XCTAssertEqual(value["state"] as? String, "restricted")
        XCTAssertEqual(value["constrained"] as? Bool, true)
        XCTAssertTrue(cost.script.contains("weq-remote-network-cost"))
    }
    func testReducedDataUpdateCheckNeverSamplesInstaller() async throws {
        let ranked = try await UpdateMirrors.resolve(prefixes: ["https://synthetic.invalid/"], sample: false) { _, range in
            XCTAssertFalse(range)
            return Data((String(repeating: "a", count: 64) + "  weq-remote-1.0.0b4-ios-arm64-unsigned.ipa\n").utf8)
        }
        XCTAssertEqual(ranked.count, 1)
    }
}
