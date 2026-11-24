import Foundation

enum RemoteThemeAccent {
    // 与 WeQ 外观设置的预设顺序和色值一致。
    static let presets = [
        ("#0099ff", "默认亮蓝"), ("#3b82f6", "蓝色"), ("#6f8aa6", "灰蓝"),
        ("#16b8a6", "青绿"), ("#32b67a", "绿色"), ("#f59e0b", "琥珀"),
        ("#ef4444", "红色"), ("#ec4899", "粉色"), ("#8b5cf6", "紫色"),
    ]
    static let defaultColor = presets[0].0

    static func normalized(_ value: String?) -> String? {
        guard let value, value.utf8.count == 7, value.first == "#",
              value.dropFirst().utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        return value.lowercased()
    }

    static func preset(_ value: String?) -> String {
        presets.first { $0.0 == value }?.0 ?? defaultColor
    }

    struct RGB {
        let red, green, blue: Double

        init(_ value: Int) {
            red = Double(value >> 16 & 255) / 255
            green = Double(value >> 8 & 255) / 255
            blue = Double(value & 255) / 255
        }

        init(hex: String, dark: Bool = false) {
            self.init(Int(hex.dropFirst(), radix: 16) ?? (dark ? 0x56a8f7 : 0x0099ff))
        }

        private init(_ r: Double, _ g: Double, _ b: Double) { red = r; green = g; blue = b }

        func mix(_ other: RGB, _ amount: Double) -> RGB {
            RGB(red + (other.red - red) * amount, green + (other.green - green) * amount, blue + (other.blue - blue) * amount)
        }

        var luminance: Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }

        var usesDarkInk: Bool { luminance >= 0.179 }

        func readable(on surface: RGB, dark: Bool) -> RGB {
            let background = surface.mix(self, 0.12).luminance + 0.05
            let target = RGB(dark ? 0xffffff : 0)
            for step in 0...20 {
                let ink = mix(target, Double(step) / 20)
                let value = ink.luminance + 0.05
                if max(value, background) / min(value, background) >= 4.5 { return ink }
            }
            return target
        }
    }
}
