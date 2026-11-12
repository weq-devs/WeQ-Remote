# WeQ Remote

WeQ 的独立手机连接客户端。iOS 与 Android 负责扫码、连接、凭据和原生 WebView，业务页面从电脑上的 WeQ Web 服务加载，不维护另一套聊天界面。

当前发布版本：iOS / Android 1.0.0b3，iOS build 11、Android versionCode 9，为 GitHub 测试版，未上架应用商店。源码仓库：[weq-devs/WeQ-Remote](https://github.com/weq-devs/WeQ-Remote)（公开，默认分支 `dev`）。版本说明见 [1.0.0b3](docs/releases/1.0.0b3.md)，安装包见 [GitHub Release](https://github.com/weq-devs/WeQ-Remote/releases/tag/v1.0.0b3)。

1.0.0b3 已于 2026-11-12（北京时间）发布，新增统一连接详情、断连提醒与更新检查，补齐 Android 旋转／全屏、iOS 网页对话框和 HTTP 页面设备采集，并保留全屏网页、停止连接、扫码更新已授权电脑、资源进度与持久缓存。两端应用内均显示 1.0.0b3；iOS 系统版本字段为 1.0.0，Beta 标识单独保存。发布提供 Android arm64 APK、iOS arm64 未签名 IPA、构建来源记录与 SHA256SUMS；iOS 安装前需正确签名 App 与内嵌 Framework，Android 使用本轮临时开发签名，签名不同时不能直接覆盖已有安装。

开发源码还接入网页设备选文件、麦克风/摄像头授权、外链、文件保存及当前界面截图。
开发源码随现有配对与状态请求上报设备型号、系统版本和 Remote 版本／构建号，供电脑「已配对设备」详情展示；已有授权自动补齐，不增加心跳，旧电脑继续兼容。需重新构建、安装手机 App 并更新电脑端；已发布安装包不会自动获得上报能力。
开发源码统一两端连接首页，系统、版本、网络与更新信息收进右上角「更多」；聊天内的连接菜单使用同一份详情，保留立即检查、重新加载和断开连接。
详情显示当前电脑入口、系统网络／内嵌 Tailscale、Tailscale 状态、最近成功验证时间、请求耗时、App 版本与构建号、手机系统版本。
开发源码的 iOS 将断连提醒与重连流程分开：前台监听系统网络变化，无可用网络持续 2 秒提示「网络已断开，恢复后自动重连」；电脑请求失败持续 3 秒，或前台连续 30 秒没有成功验证，提示「连接已中断，正在重连…」，不等待备用入口探测结束。网页同源 fetch／WebSocket 连接失败和网络恢复会触发合并检查，主动取消请求、正常关闭 WebSocket 和外部链接失败不触发。提示使用独立的一次性计时器，不增加正常连接的轮询频率；系统网络恢复本身不清除提醒，需电脑验证成功。需重新构建、安装 iOS App，已发布的 1.0.0b3 不会自动获得此修复。
两端正常连接仍在前台每 15 秒验证，失败后每 5 秒重试；Android 仍连续两轮失败才显示提醒，开发源码统一使用「连接已中断，正在重连…」。提示不销毁页面，验证成功后自动消除。后台不轮询，iOS 后台时间不计入提示时限；撤销授权仍立即按原流程清理。
「检查更新」沿用 WeQ 的加速站探测与安装包取样测速，显示当前／最新版本和选中的源，并提供下载及备用源。两端共用 `resources/update-mirrors.json`；每个测速候选最多读取 256 KiB，最多三个候选。
「检查测试版」默认关闭并保存在本机；关闭时排除 GitHub 测试发布和带 Beta 标签的版本，开启时比较正式版与测试版，取版本较新者。先读取公开发布目录，再固定到选定标签探测清单，切换选项不复用旧结果，不提示降级。
下载由系统浏览器承接，不在手机壳里静默安装；iOS 发布包仍为未签名 IPA，需要签名。上述原生变化需要重新构建、安装手机 App，不自动改版本号。
已保存电脑的首页提供「连接／停止」，左侧扫码可更新地址和 Tailscale Key；复用已有设备令牌验证新入口，不重新申请电脑授权，验证成功后才保存新地址。扫码包含新 Key 时会先完成入网；连接选路仍采用错峰竞速、首个可用入口胜出。
连接时留在首页并显示资源下载、恢复检查、账号初始化、界面绘制等实际阶段，真实界面渲染后才进入；会话和好友等业务列表在界面内异步加载，不阻塞启动。失败或超时在首页提示重试，需电脑网页和手机安装包同时更新。
Android 使用系统文件保存位置，iOS 使用系统分享菜单；这些变化需要更新手机安装包。
源码与离线构建不代表真实手机的上传、录音、通话、下载或后台运行已经验收。

连接页的下载阶段使用现有圆环显示字节比例，下方显示已加载／总大小与资源项数。
总大小来自电脑 HTML 内的首屏 JS/CSS 清单，按实际 gzip 协商计算；单个资源完成后累加数据量，缓存命中也计入已加载资源，不表示本次网络流量。
下载完成后恢复等待圆环并继续显示实际初始化阶段，不把 HTML 提交当作资源下载完成。需同步更新电脑服务与手机 App；旧电脑未给清单时不虚构总大小。

开发源码支持跨重启复用资源：iOS 使用按电脑／授权／证书标识的持久 Web 数据存储；Android 保留 WebView 缓存，并在私有 cacheDir 持久缓存带内容哈希的 immutable JS/CSS，完整接收后才写入，较旧版本按 48 MiB 预算淘汰。
Android 下载不再等待整份代码读完后才转发；HTTPS 连接尝试 HTTP/2，旧电脑自动使用 HTTP/1.1。忘记电脑或撤销授权仍清理代码缓存。

Android 开发源码为每份已保存的电脑授权保留固定的本地代理端口，重连、切换连接路径和重启 App 不再改变网页存储来源；端口不可用时提示重试，不静默换成随机端口。此项需要更新 Android 安装包，iOS 原生端不变。
昵称、备注、好友／群列表及会话摘要由电脑提供的共用 Web 页面使用 IndexedDB 保存，按网页来源和账号／配置隔离。重新进入先恢复缓存，再通过现有查询与变更订阅刷新；刷新失败保留已有数据。完整目录在首屏之后补齐，好友申请和群通知延后到联系人页，好友在线状态只在联系人页打开后查询；不新增版本检查或同步协议。业务页面需要同步更新电脑上的 WeQ。

## 仓库边界

| 本仓库 | WeQ 桌面仓库 |
| --- | --- |
| iOS / Android 手机壳、协议客户端、原生网络与缓存 | Web 页面、业务 API、QQ 数据库和业务能力 |
| 扫码、设备凭据、证书校验、WebView、手机构建测试 | 配对批准与撤销、Web 服务、电脑网络入口、桌面协议夹具 |

单纯更新业务页面只需更新电脑提供的 Web；原生连接、权限、缓存或 WebView 改动才需要更新手机安装包。独立仓库不等于可以脱离电脑运行。

## 目录与构建

两端应用图标复用 WeQ 标识，含 iOS / iPadOS 浅深色版本与 Android 自适应版本；源图、生成入口和平台规格见[图标维护](resources/brand/README.md)。

- `apps/ios`：Swift / SwiftUI，iOS 17 起。见 [iOS 构建说明](apps/ios/README.md)。
- `apps/android`：Java 原生壳与 Go 用户态网络，Android API 26 起。见 [Android 构建说明](apps/android/README.md)。
- `scripts/desktop_fixture.py`：跨仓库集成测试入口，不参与产品构建。
- `docs/protocol.md`：两边的协议兼容约定。
- `MIGRATION.md`：来源历史、迁移边界与本地验证回执。

原生产品构建不需要安装 Node/pnpm，也不依赖 WeQ 源码。需要 Xcode / Android SDK、Go 及对应平台说明中的固定依赖；iOS 沿用 `WEQ_TAILSCALE_FRAMEWORK` 指定的框架，不把它复制进仓库。

```sh
cd /path/to/WeQ-Remote
python3 -m unittest discover -s tests
swift test --package-path apps/ios --scratch-path apps/ios/.build/protocol -j 2
go -C apps/android/network test -race ./...
bash apps/android/scripts/check-protocol.sh
```

Android 的 Java 协议测试与构建共用固定版本、SHA-256 校验的 ZXing 依赖；缺失时自动准备，已有文件校验失败则停止，不覆盖原文件。SDK / 模拟器继续使用既有外盘与 guard 入口，不在 SSD 新建替代实例。

## 自动化

GitHub Actions 在 push / pull request 时运行仓库与构建辅助测试、Java 协议 / 二维码测试、Go 静态与竞态检查、macOS Swift 宿主机测试；也支持手动运行。Android 开发 APK 和 iOS 未签名真机 IPA 可分别构建，默认不发布。手动在版本标签上运行 `Release` 时，复用 CI 和两端构建，全部成功且产物校验通过后才创建 GitHub Release。iOS 从校验过的固定源码构建 TailscaleKit，不依赖私人项目或签名。触发方式、安全边界和未覆盖范围见 [自动化维护](docs/automation.md)。

## 与电脑端联调

只在集成测试时需要兼容的 WeQ 桌面 checkout（安装其锁文件对应的 pnpm 依赖）：

```sh
export WEQ_DESKTOP_REPO=/path/to/WeQ
python3 scripts/desktop_fixture.py --desktop-repo "$WEQ_DESKTOP_REPO"
```

该命令调用电脑仓库的 `scripts/remote-integration-server.ts`，默认仅监听 `127.0.0.1:45198`，使用合成数据并自动批准测试设备，不操作真实 QQ。`/test/contract` 返回夹具版本。LAN 模式加 `--lan`；隔离 TS 测试加 `--network-config /absolute/path/network-test.json` 并按平台说明启动电脑测试网络。

Android 完整测试显式选择电脑端仓库：

```sh
android-sdk-run python3 apps/android/scripts/integration.py \
  --desktop-repo "$WEQ_DESKTOP_REPO" --serial emulator-5580
```

测试结束关闭本轮服务与专用设备，不影响其他任务设备。不得对真机运行删除凭据的合成撤销测试。

从电脑仓库验证独立手机入口及真实协议往返：

```sh
cd "$WEQ_DESKTOP_REPO"
WEQ_REMOTE_CLIENT_REPO=/path/to/WeQ-Remote \
  node --test scripts/remote-integration-server.test.mjs
```

## 历史与许可

保留了手机目录的 4 条路径过滤历史，以及拆分前的完整工作区快照，详见 [迁移记录](MIGRATION.md)。源码沿用 WeQ 的 [LICENSE](LICENSE)，Tailscale 等依赖遵循各自许可。不提交签名、账号、原始凭据、节点身份或构建产物。

历史中的个人提交身份、本机路径及应用标识已脱敏；当前应用命名空间为 `io.github.weqdevs.remote`。这与旧身份安装是不同应用，不能原位升级或直接读取其 Keychain / Keystore；新构建需要单独安装并重新配对。身份清理时仅修改源码；后续自动化构建与发布不迁移设备数据，具体结果见自动化回执与发布说明。
