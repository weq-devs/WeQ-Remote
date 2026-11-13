# WeQ Remote for iOS

当前源码：1.0.0b4（build 12），不是 App Store / TestFlight 发布版。iOS 17 起。应用内版本与 `WeQReleaseVersion` 为 1.0.0b4，系统 `CFBundleShortVersionString` 为 1.0.0。见 [1.0.0b4 版本说明](../../docs/releases/1.0.0b4.md)，实际发布状态以 GitHub Releases 为准。

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

### SideStore 本机源

SideStore 可以安装并续签本项目未签名 IPA。使用与现有安装一致的 Apple
签名账户，在安装选项中关闭给业务 App 的 Bundle ID 追加 Team ID，保留
`io.github.weqdevs.remote`；不要先卸载已有同身份应用。重签后的 Keychain
凭据和冷启动重连需实机验证，不能用未签名构建通过代替。

本机正式打包可运行 `python3 apps/ios/scripts/build_unsigned_ipa.py --publish-local`，
或通过 `python3 scripts/publish_local_ios.py --ipa /absolute/path/app.ipa`
发布已有安装包。入口先检查真机 Mach-O、身份及无签名状态，再调用本机
`ios-app-distribution`；通过 `IOS_APP_DISTRIBUTION` 可指定其 CLI 路径。
该工具是可选本机集成，不进入产品依赖，不影响 CI，也不自动改版本号。
SideStore 源使用 IPA 的系统版本与 build，测试版显示名仅作说明。
官方 SideStore 0.7.0-alpha 的刷新上下文默认追加 Team ID，已有身份查找又
要求标识包含 Team ID；原标识安装的自动刷新兼容性不能仅凭安装选项推定。
需先完成相应兼容修补和真实刷新验收，再将既有安装交给自动续签管理。

### 未签名 IPA

无需证书、Apple ID 或描述文件即可从源码构建真机 arm64 IPA：

```sh
python3 apps/ios/scripts/build_unsigned_ipa.py
```

使用 `Support/.go-version` 的 Go、`Support/tailscale-dependency.json` 的 XcodeGen 版本和支持 Swift 6 的 Xcode。该入口下载并校验固定 Tailscale 源码，应用 `tailscale-privacy.patch` 后构建仅含真机 arm64 的 XCFramework；上游固定提交本身已含 `statusJSON()`，没有另加该接口补丁。

App 使用隔离临时工程和 DerivedData 编译，不覆盖现有生成工程，不创建模拟器或操作真机。IPA 默认写入 `.build/unsigned-ipa/<UTC构建标识>/`；也可用 `--output-dir /absolute/path/empty-directory` 指定空目录，已有文件不覆盖。同时生成 `SHA256SUMS` 与 `build.json`，记录来源、工具链、源码提交和工作区是否有未提交改动。中间源码及 DerivedData 自动清理，Framework 按输入指纹校验复用。

打包前检查 App 身份、iPhoneOS 平台、所有 Mach-O 的 arm64 / 真机标识和无签名状态，拒绝描述文件、签名目录、外逃链接及已有输出冲突，并保留 ZIP 中的可执行权限。该检查是产物结构校验，不是真机运行验收。

GitHub Actions 中手动运行 `iOS unsigned IPA`，临时产物保留 3 天；标签上的 `Release` 工作流另将校验通过的安装包附到 GitHub Release，见[自动化维护](../../docs/automation.md)。未签名 IPA 安装前仍须对 App 和内嵌 Framework 正确签名；重新签名时应按签名团队重建 application-identifier、Keychain access groups 和描述文件，不照搬未展开的 entitlement 模板。源码构建的纯真机 Framework 不用于模拟器测试。

## 使用

1. 新版电脑显示局域网与 WeQ 专用 Tailscale 地址，统一点击「生成配对码」。跨网络连接时启动并登录专用 Tailscale，勾选「嵌入 Tailscale Key」，点击生成后在弹窗填写 Key。
2. 手机扫码即申请连接，也可粘贴链接并点箭头或键盘「连接」。
3. 电脑弹窗批准完整 Web 访问后进入网页，后续打开自动重连，无需重复验证。
4. 电脑可删除已配对设备；网页完成恢复检查、账号探测、必要配置及真实界面绘制后全屏显示，不再保留原生导航栏或按钮。准备期间首页显示资源下载、网页初始化、恢复检查和界面绘制等具体阶段；会话和好友等业务列表在正式界面内加载，不阻塞启动。HTML 加载完成不会提前切页；失败或 45 秒超时在首页重试，需要同步更新电脑网页。需要确认的恢复回执会显示操作页面。
5. 新版网页顶栏的连接菜单提供「重新加载」「断开连接」。断开后保留电脑并暂停自动重连，首页点击「连接」恢复，连接中可点「停止」中止并暂停自动重试。连接按钮左侧的扫码按钮可更新已保存电脑的地址和 Tailscale Key，无需先删除电脑或重新批准授权；新地址用原设备令牌验证成功后才保存，带 Key 的更新先完成入网。删除电脑只在首页提供且需要确认。更换电脑使用删除后重新扫码或粘贴链接的流程。

移动网页自行处理左缘返回及页面转场，壳不再叠加 WKWebView 的原生返回手势。电脑网页和手机壳需配套更新以使用连接菜单；没有原生浮动按钮或旧网页兼容菜单。

开发源码在 iPadOS 26 起读取系统窗口角部占位，随窗口尺寸传给共用网页：顶部操作区优先与窗口控件同排，窄窗空间不足时下移；全屏自动取消额外留位，正文仍铺满。首屏显示前同步占位并等待网页绘制，不新增原生导航栏、不重建 WebView。需要同时更新 iOS 安装包与电脑提供的 Web 页面；浏览器合成占位测试和原生构建不代替真实 iPad 窗口验收。

开发源码通过 WKWebView 的公开附加栏覆写移除网页键盘上方的「上一个／下一个／完成」表单导航条，聊天工具仍由网页提供，系统候选词与文字编辑菜单不变。此项需要更新 iOS 安装包；聊天输入区的安全区适配、发送按钮和键盘发送提示由电脑提供的网页更新。原生编译及浏览器布局测试不代表 iPhone 系统键盘已经实机验收。

网页中标记为页内播放的视频（如动态名片背景）保持在页面内，不自动弹出系统全屏播放器；聊天视频仍可由用户主动进入全屏。此修复需要更新 iOS App，仅更新电脑端网页不会改变已安装 App 的 WebView 配置。

开发源码接入网页麦克风/摄像头授权、外链、新窗口交接和鉴权下载。下载完成后使用系统分享菜单，
可保存到文件或交给其他 App；网页菜单截图使用当前 WKWebView 的快照，也交给系统分享菜单。
下载沿用当前数据存储与证书指纹校验，不把网页凭据复制给系统浏览器。
HTTPS 页面沿用 WebKit 的设备采集；内嵌 Tailscale 的远端 HTTP 页面通过 `weqRemoteMedia` 本地桥使用 AVAudioEngine／AVCaptureSession，输出 16 kHz 单声道 PCM 音频和有界 RGBA 视频帧，业务发送仍由共用网页完成。采样率转换使用 AVAudioConverter，摄像头方向跟随原生 RotationCoordinator；权限拒绝、退后台、采集中断、页面重载和断开都会结束采集。此能力需要同时更新手机安装包与电脑提供的网页，不是仅增加用途说明。
网页的 JavaScript 提示、确认和输入由原生对话框承接，确认、取消和销毁只回调一次。
跨源外链由 `weqRemoteLinks.open` 本地桥交给系统；机器人控制台、频道登录等异步获取的链接不再依赖 `window.open` 当时仍保留用户激活。同源下载与 Blob 保留在当前鉴权下载链路，不交给系统浏览器，也不覆盖聊天页面。
手机屏幕共享、原生推送、后台持续通话与真实 iPhone 验收仍未完成。

设备凭据保存在 ThisDeviceOnly Keychain。已连接时退后台保留内存中的 WKWebView 与连接对象，返回前台校验授权，不主动重建网页；连接暂时不可用时保留页面并重试，401 撤销授权仍清除凭据与网页。未完成的配对在后台取消。系统回收进程后的冷启动从 Keychain 自动重连，不承诺恢复未保存的网页状态；不申请后台保活。TS 节点身份保留在 App 私有 Application Support，并排除系统备份；WKWebView 按电脑地址、授权和证书使用稳定的持久数据存储，跨重启复用资源与网页偏好，忘记电脑时清空当前及已保存入口的数据存储。内嵌模式 SOCKS 代理禁止失败后退回直连；局域网模式使用系统路由和精确证书指纹校验，不启动内嵌节点。

当前开发源码新增 v4 多入口邀请，保留全部地址，连接时错峰探测并采用首个可用入口，不逐个等待不可达地址超时；已配对设备恢复连接时的探测就是一次鉴权状态读取，成功结果直接用于本次连接，不再重复核验，也不把 3 秒探测超时当作入口不可用。内嵌入网不再阻塞可用的 HTTPS 直连。等待电脑批准时，临时超时会保留本次配对并重试，v4 可切换入口继续读取批准结果。Key 用于 App 内置 Tailscale 加入电脑所在网络。已发布的 0.1.0 尚不支持 v4，需要新版 App。继续支持旧 v1、带 Key/有效期的 v2 和带局域网 HTTPS 指纹的 v3。除 v4 的不同 `endpoint` 外拒绝重复/额外字段、公网域名、回环和控制面替换。ATS 例外限定私有 IPv4 / TS 网段；LAN 协议仍强制 HTTPS 且仅接受二维码中的指纹，不接受任意自签名证书。

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
