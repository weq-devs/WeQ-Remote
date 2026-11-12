import Foundation

struct ConnectionHealth {
    enum Warning: Equatable {
        case network, connection

        var message: String {
            switch self {
            case .network: return "网络已断开，恢复后自动重连"
            case .connection: return "连接已中断，正在重连…"
            }
        }
    }

    private(set) var warning: Warning?
    private(set) var networkAvailable = true
    private(set) var checkedAt: Date?
    private(set) var latency: Int?
    private var lastResponse: TimeInterval?
    private var failureSince: TimeInterval?
    private var noNetworkSince: TimeInterval?
    private var retryWarningAt: TimeInterval?
    private(set) var failedChecks = 0

    var requestTimeout: TimeInterval { 5 * (Double(failedChecks) + 1) }
    var checkInterval: TimeInterval { failedChecks == 0 ? 15 : 0.5 }

    mutating func beginCheck(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if failedChecks > 0, retryWarningAt == nil { retryWarningAt = now + 5 }
    }

    mutating func checkFailed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        failedChecks += 1
        failed(now: now)
    }

    var status: String { warning == .network ? "网络已断开" : warning != nil ? "连接已中断" : checkedAt == nil ? "待检查" : "已连接" }

    var nextDeadline: TimeInterval? {
        var deadlines: [TimeInterval] = []
        if warning == nil {
            if let noNetworkSince { deadlines.append(noNetworkSince + 10) }
            if let failureSince { deadlines.append(failureSince + 10) }
            if let retryWarningAt { deadlines.append(retryWarningAt) }
            if let lastResponse { deadlines.append(lastResponse + 30) }
        }
        return deadlines.min()
    }

    mutating func succeeded(at date: Date, latency: Int?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        warning = nil
        checkedAt = date
        self.latency = latency
        lastResponse = now
        failureSince = nil
        noNetworkSince = nil
        retryWarningAt = nil
        failedChecks = 0
    }

    mutating func failed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if failureSince == nil { failureSince = now }
    }

    mutating func networkChanged(available: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        networkAvailable = available
        if available {
            noNetworkSince = nil
            if warning == .network { warning = .connection }
        } else if noNetworkSince == nil {
            noNetworkSince = now
            if warning != nil { warning = .network }
        }
    }

    // 第二轮等到 5 秒就提醒，不取消其剩余预算；备用入口也共用该轮预算。
    mutating func evaluate(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let noNetworkSince, now - noNetworkSince >= 10 {
            warning = .network
        } else if warning != .network,
                  failureSince.map({ now - $0 >= 10 }) == true || retryWarningAt.map({ now >= $0 }) == true || lastResponse.map({ now - $0 >= 30 }) == true {
            warning = networkAvailable ? .connection : .network
        }
    }

    mutating func resume(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastResponse = now
        failureSince = nil
        retryWarningAt = nil
        failedChecks = 0
        noNetworkSince = networkAvailable ? nil : now
    }

    // 后台时间不计入失联时限，已有提醒只在实际验证成功后消除。
    mutating func suspend() {
        lastResponse = nil
        failureSince = nil
        noNetworkSince = nil
        retryWarningAt = nil
    }
}
