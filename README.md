# WeQ Remote

WeQ 的独立手机连接客户端。iOS 与 Android 负责扫码、连接、凭据和原生 WebView，业务页面从电脑上的 WeQ Web 服务加载，不维护另一套聊天界面。

当前版本：iOS / Android [0.2.0](https://github.com/weq-devs/WeQ-Remote/releases/tag/v0.2.0)，iOS build 7、Android versionCode 5。安装包仍为开发测试用途，未上架应用商店。源码仓库：[weq-devs/WeQ-Remote](https://github.com/weq-devs/WeQ-Remote)（私有，默认分支 `dev`）。发布说明见 [0.2.0](docs/releases/0.2.0.md)。

当前源码版本为 0.2.0，包含 v4 多入口配对、原生连接页调整及前后台网页保留；发布内容与安装包说明见 [0.2.0](docs/releases/0.2.0.md)。实际发布状态以 [GitHub Releases](https://github.com/weq-devs/WeQ-Remote/releases) 为准。

开发源码还接入网页设备选文件、麦克风/摄像头授权、外链、文件保存及当前界面截图。
连接时留在首页，等待电脑网页完成恢复检查、账号探测和首屏关键数据准备后再进入；失败或超时在首页提示重试，需电脑网页和手机安装包同时更新。
Android 使用系统文件保存位置，iOS 使用系统分享菜单；这些变化需要更新手机安装包。
源码与离线构建不代表真实手机的上传、录音、通话、下载或后台运行已经验收。

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
