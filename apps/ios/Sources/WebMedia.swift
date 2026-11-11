import Foundation

struct WebMediaRequest {
    struct Video: Equatable {
        let width: Int
        let height: Int
        let fps: Int
        let front: Bool
    }
    let id: String
    let audio: Bool
    let video: Video?

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-"
        }
    }

    init?(message: [String: Any]) {
        guard let id = message["id"] as? String, Self.validID(id) else { return nil }
        self.id = id
        audio = message["audio"] as? Bool == true
        if let options = message["video"] as? [String: Any] {
            video = Video(width: max(16, min(640, options["width"] as? Int ?? 320)),
                          height: max(16, min(480, options["height"] as? Int ?? 184)),
                          fps: max(1, min(15, options["fps"] as? Int ?? 15)),
                          front: options["facingMode"] as? String != "environment")
        } else { video = nil }
        guard audio || video != nil else { return nil }
    }
}

/** AVAudioConverter 提供 16 kHz 单声道样本，每包 20 ms，跨 tap 保留不足一包的数据。 */
struct WebMediaPCMEncoder {
    private var pending: [Int16] = []

    mutating func append(_ samples: [Float]) -> [Data] {
        for sample in samples {
            pending.append(Int16(max(-32768, min(32767, (sample.isFinite ? sample : 0) * 32768))).littleEndian)
        }
        var packets: [Data] = []
        var consumed = 0
        while pending.count - consumed >= 320 {
            packets.append(pending.withUnsafeBytes { bytes in
                Data(bytes: bytes.baseAddress!.advanced(by: consumed * 2), count: 640)
            })
            consumed += 320
        }
        if consumed > 0 { pending.removeFirst(consumed) }
        return packets
    }
}

/** 按钮、取消和销毁可能先后到达，WebKit completion 只能完成一次。 */
final class WebDialogCompletion<Value> {
    private let lock = NSLock()
    private let cancelled: Value
    private var callback: ((Value) -> Void)?
    init(cancelled: Value, callback: @escaping (Value) -> Void) {
        self.cancelled = cancelled
        self.callback = callback
    }
    func finish(_ value: Value) {
        lock.lock()
        let action = callback
        callback = nil
        lock.unlock()
        action?(value)
    }
    func cancel() { finish(cancelled) }
}
