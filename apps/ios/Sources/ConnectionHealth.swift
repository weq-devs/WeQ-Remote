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

    var status: String { warning == .network ? "网络已断开" : warning != nil ? "连接已中断" : checkedAt == nil ? "待检查" : "已连接" }

    var nextDeadline: TimeInterval? {
        var deadlines: [TimeInterval] = []
        if warning != .network, let noNetworkSince { deadlines.append(noNetworkSince + 2) }
        if warning == nil {
            if let failureSince { deadlines.append(failureSince + 3) }
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
        }
    }

    // 使用单调时间，提示不等待请求超时、备用入口探测或第二轮重连。
    mutating func evaluate(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let noNetworkSince, now - noNetworkSince >= 2 {
            warning = .network
        } else if warning != .network,
                  failureSince.map({ now - $0 >= 3 }) == true || lastResponse.map({ now - $0 >= 30 }) == true {
            warning = .connection
        }
    }

    mutating func resume(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastResponse = now
        failureSince = nil
        noNetworkSince = networkAvailable ? nil : now
    }

    // 后台时间不计入失联时限，已有提醒只在实际验证成功后消除。
    mutating func suspend() {
        lastResponse = nil
        failureSince = nil
        noNetworkSince = nil
    }
}
