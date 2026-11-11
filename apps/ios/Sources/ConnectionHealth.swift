import Foundation

struct ConnectionHealth {
    private(set) var failures = 0
    private(set) var suspected = false
    private(set) var checkedAt: Date?
    private(set) var latency: Int?

    var status: String { suspected ? "疑似断连" : checkedAt == nil ? "待检查" : "已连接" }

    mutating func succeeded(at date: Date, latency: Int?) {
        failures = 0
        suspected = false
        checkedAt = date
        self.latency = latency
    }

    mutating func failed() {
        failures = min(failures + 1, 2)
        suspected = suspected || failures >= 2
    }

    // 后台不累计连续失败，已有提醒等实际验证成功后再消除。
    mutating func suspend() { failures = 0 }
}
