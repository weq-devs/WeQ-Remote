// swift-tools-version: 5.9
import PackageDescription

// 协议单测在宿主机运行，不创建模拟器；App 仍由 XcodeGen 构建。
let package = Package(
    name: "WeQRemoteProtocol",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "WeQRemote", path: "Sources",
                exclude: ["EmbeddedNetwork.swift", "RemoteModel.swift", "ScannerView.swift", "WeQRemoteApp.swift", "WebContainer.swift"],
                sources: ["RemoteProtocol.swift", "WebDataStore.swift"]),
        .testTarget(name: "WeQRemoteProtocolTests", dependencies: ["WeQRemote"], path: "Tests",
                    exclude: ["EmbeddedConnectionTests.swift", "WebContainerTests.swift"], sources: ["RemoteProtocolTests.swift", "WebDataStoreTests.swift"]),
    ]
)
