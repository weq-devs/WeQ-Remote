#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO

// 使用仓库内的 WeQ 原始标识生成平台尺寸；普通构建直接使用已提交的资源。
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("resources/brand/weq.png")
guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil),
      let logo = CGImageSourceCreateImageAtIndex(reader, 0, nil),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
    fatalError("无法读取 WeQ 标识")
}

func render(_ relativePath: String, size: Int, logoFraction: Double, background: CGFloat?) throws {
    let alpha = background == nil ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: colorSpace, bitmapInfo: alpha.rawValue) else {
        fatalError("无法创建图标画布")
    }
    if let background {
        context.setFillColor(CGColor(gray: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    context.interpolationQuality = .high
    let scale = Double(size) * logoFraction / Double(max(logo.width, logo.height))
    let width = Double(logo.width) * scale
    let height = Double(logo.height) * scale
    context.draw(logo, in: CGRect(x: (Double(size) - width) / 2,
                                  y: (Double(size) - height) / 2, width: width, height: height))
    let output = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let image = context.makeImage(),
          let writer = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("无法写入图标：\(relativePath)")
    }
    CGImageDestinationAddImage(writer, image, nil)
    guard CGImageDestinationFinalize(writer) else { fatalError("图标写入失败") }
}

let catalog = "apps/ios/Assets.xcassets/AppIcon.appiconset"
try render("\(catalog)/AppIcon.png", size: 1024, logoFraction: 0.8, background: 1)
try render("\(catalog)/AppIcon-dark.png", size: 1024, logoFraction: 0.8, background: 0.08)

for (density, factor) in [("mdpi", 1.0), ("hdpi", 1.5), ("xhdpi", 2.0), ("xxhdpi", 3.0), ("xxxhdpi", 4.0)] {
    let folder = "apps/android/res/mipmap-\(density)"
    for name in ["ic_launcher", "ic_launcher_round"] {
        try render("\(folder)/\(name).png", size: Int(48 * factor), logoFraction: 0.8, background: 1)
    }
    // 前景限制在中央 60dp，给 66dp 安全区及不同系统蒙版留出余量。
    try render("\(folder)/ic_launcher_foreground.png", size: Int(108 * factor),
               logoFraction: 60.0 / 108, background: nil)
}
print("已生成 iOS / Android 图标")
