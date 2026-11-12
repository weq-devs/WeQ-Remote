import Foundation

struct RemoteWindowLayout: Codable, Equatable {
    struct Corner: Codable, Equatable {
        var width: Double = 0
        var height: Double = 0
    }

    var width: Double = 0
    var height: Double = 0
    var topLeft = Corner()
    var topRight = Corner()

    var hasCornerOverlap: Bool {
        (topLeft.width > 0 && topLeft.height > 0) || (topRight.width > 0 && topRight.height > 0)
    }

    var json: String {
        guard let data = try? JSONEncoder().encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
