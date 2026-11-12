import Foundation

var health = ConnectionHealth()
while let line = readLine() {
    let fields = line.split(separator: "\t").map(String.init)
    let now = Double(fields[1])! / 1000
    switch fields[0] {
    case "resume": health.resume(now: now)
    case "suspend": health.suspend()
    case "begin": health.beginCheck(now: now)
    case "failed": health.failed(now: now)
    case "checkFailed": health.checkFailed(now: now)
    case "network": health.networkChanged(available: fields[2] == "1", now: now)
    case "evaluate": health.evaluate(now: now)
    case "success": health.succeeded(at: Date(), latency: 42, now: now)
    default: fatalError("unknown operation")
    }
    let state = health.warning == .network ? "network" : health.warning == .connection ? "connection" : "connected"
    print("\(state)\t\(Int(health.requestTimeout * 1000))\t\(health.nextDeadline.map { Int(($0 * 1000).rounded()) } ?? -1)")
}
