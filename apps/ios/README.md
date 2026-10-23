# WeQ Remote for iOS

版本：0.3.2，本地开发测试版，不是 App Store / TestFlight 发布版。iOS 17 起。

薄壳结构：内嵌 TS、扫码配对和 WKWebView，业务界面复用电脑提供的 WeQ Web。手机壳已独立于 WeQ 仓库；构建不依赖桌面源码，协议边界见[协议约定](../../docs/protocol.md)，本机电脑侧用法见 [Web 与手机连接](../../../WeQ-upstream/docs/guide/remote-web.md)。

## 构建

通过 `WEQ_TAILSCALE_FRAMEWORK` 显式指定 TailscaleKit，不依赖开发者的其他项目路径。来源与初始构建指纹在 `Support/tailscale-dependency.json`，BSD 许可证随 App 打包。Framework 必须包含 `TailscaleNode.statusJSON()`，并支持 iOS 真机及模拟器。

```sh
cd /path/to/WeQ-Remote
export WEQ_TAILSCALE_FRAMEWORK=/absolute/path/TailscaleKit.xcframework
bash apps/ios/scripts/generate-project.sh
xcodebuild -project apps/ios/WeQRemote.xcodeproj -scheme WeQRemote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath apps/ios/.build/DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

其他机器通过 `WEQ_TAILSCALE_FRAMEWORK=/absolute/path/TailscaleKit.xcframework` 指定匹配框架再运行生成脚本。XcodeGen 的环境变量路径只写入可再生的 Xcode 工程，不提交本机绝对依赖路径。

模拟器验证持久凭据同样需要 ad-hoc 签名和生成工程中的 Keychain entitlement；`CODE_SIGNING_ALLOWED=NO` 只能验证编译，不能据此验收 Keychain 保存。

真机安装需要有效的开发签名和包含目标设备的描述文件；可通过 Xcode 或 `devicectl device install app` 安装。无签名真机构建不等于可安装 IPA，不上传到 TestFlight/App Store，也不替换其他 App。

### 未签名 IPA

无需证书、Apple ID 或描述文件即可从源码构建真机 arm64 IPA：

```sh
python3 apps/ios/scripts/build_unsigned_ipa.py
```

使用 `Support/.go-version` 的 Go、`Support/tailscale-dependency.json` 的 XcodeGen 版本和支持 Swift 6 的 Xcode。该入口下载并校验固定 Tailscale 源码，应用 `tailscale-privacy.patch` 后构建仅含真机 arm64 的 XCFramework；上游固定提交本身已含 `statusJSON()`，没有另加该接口补丁。

App 使用隔离临时工程和 DerivedData 编译，不覆盖现有生成工程，不创建模拟器或操作真机。IPA 默认写入 `.build/unsigned-ipa/<UTC构建标识>/`；也可用 `--output-dir /absolute/path/empty-directory` 指定空目录，已有文件不覆盖。同时生成 `SHA256SUMS` 与 `build.json`，记录来源、工具链、源码提交和工作区是否有未提交改动。中间源码及 DerivedData 自动清理，Framework 按输入指纹校验复用。

打包前检查 App 身份、iPhoneOS 平台、所有 Mach-O 的 arm64 / 真机标识和无签名状态，拒绝描述文件、签名目录、外逃链接及已有输出冲突，并保留 ZIP 中的可执行权限。该检查是产物结构校验，不是真机运行验收。

GitHub Actions 中手动运行 `iOS unsigned IPA`，产物保留 3 天，见[自动化维护](../../docs/automation.md)。未签名 IPA 安装前仍须对 App 和内嵌 Framework 正确签名；重新签名时应按签名团队重建 application-identifier、Keychain access groups 和描述文件，不照搬未展开的 entitlement 模板。源码构建的纯真机 Framework 不用于模拟器测试。

## 使用

1. 电脑选择「局域网」直接生成二维码；或进入「Tailscale」选择手机已有/没有 Tailscale。已有时无需 Key，没有时完成电脑验证、填 Key 后生成二维码。
2. 手机扫码即申请连接，也可粘贴链接并点箭头或键盘「连接」。
3. 电脑弹窗批准完整 Web 访问后进入网页，后续打开自动重连，无需重复验证。
4. 电脑可删除已配对设备，手机工具栏可删除本机保存的电脑凭据。

设备凭据保存在 ThisDeviceOnly Keychain；退到后台关闭连接，返回后从 Keychain 恢复。TS 节点身份保留在 App 私有 Application Support，并排除系统备份；WKWebView 使用非持久数据存储。内嵌模式 SOCKS 代理禁止失败后退回直连；局域网模式使用系统路由和精确证书指纹校验，不启动内嵌节点。

支持旧 v1、带 Key/有效期的 v2 和带局域网 HTTPS 指纹的 v3；拒绝重复/额外字段、公网域名、回环和控制面替换。ATS 例外限定私有 IPv4 / TS 网段；LAN 协议仍强制 HTTPS 且仅接受二维码中的指纹，不接受任意自签名证书。

## 验证

单元测试覆盖邀请解析、目的地址约束、凭据生成、状态协议校验。UI 测试使用原生 App 和电脑端实际的 `RemotePairing` / `createRemoteServer`，不是假 JSON 页面。

普通回环集成测试服务：

```sh
python3 scripts/desktop_fixture.py --desktop-repo /path/to/WeQ
```

仅监听 `127.0.0.1:45198`。它会自动批准测试请求，绝不是产品服务。测试结束关闭进程。
Debug 模拟器测试标志 `--remote-integration-test` 允许通过回环测试真实协议；仅在同时设置合法 `WEQ_REMOTE_TEST_ENDPOINT` 时生效。真机和 Release 编译不含该入口。

隔离 TS 集成网络由电脑仓库的 `tools/remote-network/ios-test-network` 提供，它启动本地控制面、DERP 与正式电脑端网络辅助程序，不注册公共网络。先用 `--network-config "$PWD/apps/ios/.build/network-test.json"` 启动上述夹具，另一个终端运行下面的网络进程。配置在手机仓库的 `.build`，不会进入 Git；UI 测试从 HTTP 夹具读取配置后，以 `--remote-ts-integration-test` 和仅回环的 `WEQ_REMOTE_TEST_CONTROL` 启动手机内嵌 TS。

```sh
export WEQ_DESKTOP_REPO=/path/to/WeQ
node "$WEQ_DESKTOP_REPO/scripts/prepare-remote-network.mjs"
go -C "$WEQ_DESKTOP_REPO/tools/remote-network" build \
  -o "$PWD/apps/ios/.build/ios-test-network" ./ios-test-network
apps/ios/.build/ios-test-network \
  --helper "$WEQ_DESKTOP_REPO/tools/remote-network/weq-remote-network" \
  --config "$PWD/apps/ios/.build/network-test.json"
```

另一个终端运行测试（测试期间保留上述两个进程）：

```sh
xcodebuild -project apps/ios/WeQRemote.xcodeproj -scheme WeQRemote \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath apps/ios/.build/DerivedData -parallel-testing-enabled NO \
  -collect-test-diagnostics never -test-timeouts-enabled YES \
  CODE_SIGNING_ALLOWED=NO test
```

测试后关闭两个本轮进程及使用的模拟设备，不关闭其他任务设备。隔离 TS 通过不代表真实 iPhone 蜂窝网络、公网控制面登录、相机扫码或 App 分发已验收；实际结果另记。

协议单测可直接在宿主机运行，不创建模拟器：`swift test --package-path apps/ios --scratch-path apps/ios/.build/protocol -j 2`。
模拟器必须使用 f 盘设备集及 `ios-simulator-run` / `ios-simctl` 入口，不能直接使用默认设备集启动设备。


## 0.1.0 历史回执（2026-10-22）

- iOS 27.0 / iPhone 18 Pro 模拟器：6 项单元/连接测试 + 2 项 UI 测试全部通过，无跳过。包含手机内嵌 TS → 本地 DERP/直连 → 正式电脑网络辅助程序 → 真实配对/状态接口，撤销后的 401 拒绝也通过。
- 最后追加网络关闭/重建的安全收尾后，单独重跑真实 TS 连接、撤销、节点重建测试，通过；完整 8 项结果在 `.build/FinalConnectionTests.xcresult`，最新生命周期结果在 `.build/LifecycleTests.xcresult`。
- 真机 arm64 Release 与模拟器 Debug 构建通过；真机 App 未签名，未安装到真实 iPhone，未上传到 TestFlight/App Store。
- 电脑端 16 项针对性测试、Node/Web 类型检查通过；Go 构建、静态检查通过。未跑全仓 CI。
- 真实连通截图导出至仓库 `.codex-local/remote-ios-20261022/screenshots/`，画面中的网络标注为本机 TS 集成测试；不含邀请或凭据，不是手填的假在线状态。
- 测试过程曾因系统合并的无障碍标签导致两项 UI 断言失败，已添加明确的无障碍标识并修复，最终重跑通过；首轮冗长诊断收集被主动中止，不计为通过。
- 测试服务、隔离网络与辅助进程已关闭，使用的模拟设备已停止。

编译产物（可再生、不入 Git）：

- 模拟器：`/path/to/WeQ-Remote/apps/ios/.build/DerivedData/Build/Products/Debug-iphonesimulator/WeQRemote.app`
- 真机未签名：`/path/to/WeQ-Remote/apps/ios/.build/DeviceBuild/Build/Products/Release-iphoneos/WeQRemote.app`

上述历史产物与缓存随手机目录原地迁移。旧日志中的原始路径不改写；生成的 Xcode 工程需重新运行生成脚本，不用旧路径软链接兼容。

依赖文档：[TailscaleKit](https://github.com/tailscale/libtailscale/tree/d1dc45d039edb7759ecbee6ba2aea0c4bca884b8/swift)、[Apple ATS 网段例外](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains)。
