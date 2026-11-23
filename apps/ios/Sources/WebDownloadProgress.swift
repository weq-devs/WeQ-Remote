import Foundation
import CoreFoundation

struct WebDownloadProgress: Equatable {
    static let loadingMessage = "正在加载网页资源"
    let completed: Int
    let total: Int
    let loadedBytes: Int64
    let totalBytes: Int64
    let downloadedBytes: Int64?
    let cachedBytes: Int64
    let unknownBytes: Int64

    init?(message: Any) {
        guard let fields = message as? [String: Any] else { return nil }
        func number(_ key: String) -> Int64? {
            progressNumber(fields[key])
        }
        guard let completed = number("completed"), let total = number("total"),
              let loaded = number("loadedBytes"), let size = number("totalBytes") else { return nil }
        let keys = ["downloadedBytes", "cachedBytes", "unknownBytes"]
        if keys.contains(where: { fields[$0] != nil }) {
            guard let downloaded = number(keys[0]), let cached = number(keys[1]), let unknown = number(keys[2]) else { return nil }
            self.init(completed: Int(completed), total: Int(total), loadedBytes: loaded, totalBytes: size,
                      downloadedBytes: downloaded, cachedBytes: cached, unknownBytes: unknown)
        } else {
            self.init(completed: Int(completed), total: Int(total), loadedBytes: loaded, totalBytes: size)
        }
    }

    init?(completed: Int, total: Int, loadedBytes: Int64, totalBytes: Int64,
          downloadedBytes: Int64? = nil, cachedBytes: Int64 = 0, unknownBytes: Int64? = nil) {
        guard total > 0, total <= 4096, completed >= 0, completed <= total,
              totalBytes > 0, totalBytes <= 1 << 40, loadedBytes >= 0, loadedBytes <= totalBytes,
              (completed == total) == (loadedBytes == totalBytes) else { return nil }
        let unknown = unknownBytes ?? loadedBytes
        guard cachedBytes >= 0, cachedBytes <= loadedBytes, unknown >= 0, unknown <= loadedBytes - cachedBytes,
              downloadedBytes.map({ $0 >= 0 && $0 <= 1 << 40 }) ?? (cachedBytes == 0 && unknown == loadedBytes) else { return nil }
        self.completed = completed
        self.total = total
        self.loadedBytes = loadedBytes
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.cachedBytes = cachedBytes
        self.unknownBytes = unknown
    }

    var fraction: Double { Double(loadedBytes) / Double(totalBytes) }
    var downloading: Bool { completed < total }
    var fullyCached: Bool { completed == total && downloadedBytes == 0 && cachedBytes == totalBytes && unknownBytes == 0 }
    var detail: String {
        if fullyCached { return "已复用网页缓存" }
        var lines = ["资源加载 \(progressBytes(loadedBytes)) / \(progressBytes(totalBytes))"]
        if let downloadedBytes { lines.append("已确认下载 \(progressBytes(downloadedBytes)) · 缓存复用 \(progressBytes(cachedBytes))") }
        if unknownBytes > 0 { lines.append("来源待确认 \(progressBytes(unknownBytes))") }
        lines.append("资源 \(completed) / \(total) 项")
        return lines.joined(separator: "\n")
    }
}

struct WebDevelopmentProgress: Equatable {
    let completed: Int64
    let downloadedBytes: Int64
    let cached: Int64
    let unknown: Int64

    init?(message: Any) {
        guard let fields = message as? [String: Any],
              let completed = progressNumber(fields["completed"]), completed <= Int64(Int32.max),
              let downloadedBytes = progressNumber(fields["downloadedBytes"]),
              let cached = progressNumber(fields["cached"]), cached <= completed,
              let unknown = progressNumber(fields["unknown"]), unknown <= completed - cached,
              (downloadedBytes == 0 || cached + unknown < completed) else { return nil }
        self.completed = completed
        self.downloadedBytes = downloadedBytes
        self.cached = cached
        self.unknown = unknown
    }

    var detail: String {
        "已确认下载 \(progressBytes(downloadedBytes))\n缓存复用 \(cached) 项 · 来源待确认 \(unknown) 项"
    }
}

private func progressNumber(_ field: Any?) -> Int64? {
    guard let number = field as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let value = number.doubleValue
    guard value.isFinite, value >= 0, value <= Double(Int64(1) << 40),
          value.rounded(.towardZero) == value else { return nil }
    return number.int64Value
}

private func progressBytes(_ value: Int64) -> String {
    value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}
