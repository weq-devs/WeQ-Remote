import Foundation
import CoreFoundation

struct WebResourceProgress: Equatable {
    static let preparingMessage = "正在准备网页资源"
    let completed: Int
    let total: Int

    init?(message: Any) {
        guard let fields = message as? [String: NSNumber] else { return nil }
        var numbers: [Int64] = []
        for key in ["completed", "total"] {
            guard let number = fields[key] else { return nil }
            let value = number.doubleValue
            guard CFGetTypeID(number) != CFBooleanGetTypeID(),
                  value.isFinite, value >= 0, value <= 4096,
                  value.rounded(.towardZero) == value else { return nil }
            numbers.append(number.int64Value)
        }
        self.init(completed: Int(numbers[0]), total: Int(numbers[1]))
    }

    init?(completed: Int, total: Int) {
        guard total > 0, total <= 4096, completed >= 0, completed <= total else { return nil }
        self.completed = completed
        self.total = total
    }

    var stage: String { completed < total ? Self.preparingMessage : "正在初始化网页" }
    var detail: String { "网页资源已就绪 \(completed) / \(total) 项" }
}
