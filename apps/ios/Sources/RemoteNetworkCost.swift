import Foundation

struct RemoteNetworkCost: Encodable, Equatable, Sendable {
    let state: String
    let constrained: Bool
    let metered: Bool
    let source = "apple-network"
    init(available: Bool, constrained: Bool, metered: Bool) {
        self.state = available ? (constrained || metered ? "restricted" : "unrestricted") : "unknown"
        self.constrained = constrained
        self.metered = metered
    }
    static let unknown = RemoteNetworkCost(available: false, constrained: false, metered: false)
    var restricted: Bool { state == "restricted" }
    var json: String { String(data: (try? JSONEncoder().encode(self)) ?? Data(), encoding: .utf8) ?? "null" }
    var script: String { "window.weqRemoteNetworkCost=\(json);window.dispatchEvent(new Event('weq-remote-network-cost'));" }
}
