# WeQ Remote for iOS

支持 iOS 17 及以上。安装和配对见[项目首页](../../README.md#安装与连接)。

## Xcode 构建

使用支持 Swift 6 的 Xcode、[固定版本 Go](Support/.go-version)和 [XcodeGen](Support/tailscale-dependency.json)。TailscaleKit 需包含 `TailscaleNode.statusJSON()` 与 WeQ 本机网页入口，可由 [build_tailscale.py](scripts/build_tailscale.py) 构建。默认生成真机框架，加 `--simulator` 生成 Apple Silicon 模拟器框架。

以下命令使用模拟器版本的框架，从仓库根目录生成工程并编译。

```sh
export WEQ_TAILSCALE_FRAMEWORK=/absolute/path/TailscaleKit.xcframework
bash apps/ios/scripts/generate-project.sh
ios-simulator-run xcodebuild -project apps/ios/WeQRemote.xcodeproj -scheme WeQRemote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apps/ios/.build/DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

真机调试可由 Xcode 签名安装，或用 `devicectl device install app` 安装已签名的 App。描述文件须包含目标设备。模拟器的 Keychain 持久化测试需 ad-hoc 签名和工程中的 Keychain entitlement。

## 未签名 IPA 与 SideStore

生成安装包前按[仓库约定](../../AGENTS.md)递增 iOS 构建号。

```sh
python3 apps/ios/scripts/build_unsigned_ipa.py
```

脚本校验固定 Tailscale 源码、应用仓库补丁，在隔离工程构建真机 arm64。IPA、`build.json` 和 `SHA256SUMS` 默认输出到 `apps/ios/.build/unsigned-ipa/<UTC 构建标识>/`。`--output-dir` 可指定空目录。安装前须正确签名 App 和内嵌 Framework，并按签名团队配置 application-identifier、Keychain access groups 和描述文件。云端构建见[自动化](../../docs/automation.md)。

本机 SideStore 源可在构建命令后加 `--publish-local` 发布新包，或用 `python3 scripts/publish_local_ios.py --ipa /absolute/path/app.ipa` 发布现有包。`IOS_APP_DISTRIBUTION` 可指定本机发布 CLI。源取 IPA 的系统版本与 build。

保留已有 SideStore 安装时，使用原签名账户并关闭给 App 的 Bundle ID 追加 Team ID，使标识继续为 `io.github.weqdevs.remote`。保留原应用身份的自动刷新仍待实机验证，续签后应核对 Keychain 与冷启动重连。

## 验证

```sh
swift test --package-path apps/ios --scratch-path apps/ios/.build/protocol -j 2
```

### 模拟器联调

使用外盘设备集（`ios-simulator-run`／`ios-simctl`）。按[联调夹具](../../docs/protocol.md#联调夹具)启动电脑测试服务，验证局域网恢复时加 `--lan`。要跑隔离 Tailscale，改为传入 `--network-config "$PWD/apps/ios/.build/network-test.json"`，并用下列命令在另一终端启动测试控制面、DERP 与电脑网络助手。

```sh
export WEQ_DESKTOP_REPO=/path/to/WeQ
node "$WEQ_DESKTOP_REPO/scripts/prepare-remote-network.mjs"
mkdir -p apps/ios/.build
go -C "$WEQ_DESKTOP_REPO/tools/remote-network" build \
  -o "$PWD/apps/ios/.build/ios-test-network" ./ios-test-network
apps/ios/.build/ios-test-network \
  --helper "$WEQ_DESKTOP_REPO/tools/remote-network/weq-remote-network" \
  --config "$PWD/apps/ios/.build/network-test.json"
```

测试通过夹具读取回环控制面和入口。这些启动参数只在 Debug 模拟器生效。将示例中的 UDID 替换为本轮专用设备的标识。

```sh
ios-simulator-run xcodebuild -project apps/ios/WeQRemote.xcodeproj -scheme WeQRemote \
  -destination 'platform=iOS Simulator,id=<模拟器 UDID>' \
  -derivedDataPath apps/ios/.build/DerivedData -parallel-testing-enabled NO \
  -collect-test-diagnostics never -test-timeouts-enabled YES \
  CODE_SIGNING_ALLOWED=NO test
```

结束后关闭本轮夹具、隔离网络和模拟设备。相机、真实蜂窝网络及续签需在对应真机上验证。
