import Foundation

struct WebDownloadProgress: Equatable {
    let completed: Int
    let total: Int
    let loadedBytes: Int64
    let totalBytes: Int64

    init?(message: Any) {
        guard let fields = message as? [String: NSNumber] else { return nil }
        var numbers: [Int64] = []
        for key in ["completed", "total", "loadedBytes", "totalBytes"] {
            guard let number = fields[key] else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value <= Double(Int64(1) << 40),
                  value.rounded(.towardZero) == value else { return nil }
            numbers.append(number.int64Value)
        }
        self.init(completed: Int(numbers[0]), total: Int(numbers[1]), loadedBytes: numbers[2], totalBytes: numbers[3])
    }

    init?(completed: Int, total: Int, loadedBytes: Int64, totalBytes: Int64) {
        guard total > 0, total <= 4096, completed >= 0, completed <= total,
              totalBytes > 0, totalBytes <= 1 << 40, loadedBytes >= 0, loadedBytes <= totalBytes,
              (completed == total) == (loadedBytes == totalBytes) else { return nil }
        self.completed = completed
        self.total = total
        self.loadedBytes = loadedBytes
        self.totalBytes = totalBytes
    }

    var fraction: Double { Double(loadedBytes) / Double(totalBytes) }
    var downloading: Bool { completed < total }
    var detail: String {
        "已加载 \(ByteCountFormatter.string(fromByteCount: loadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))\n资源 \(completed) / \(total) 项"
    }
}
