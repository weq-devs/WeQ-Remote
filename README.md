# WeQ Remote

WeQ 的独立手机连接客户端。iOS 与 Android 负责扫码、连接、凭据和原生 WebView，业务页面从电脑上的 WeQ Web 服务加载，不维护另一套聊天界面。

当前版本：iOS 0.3.2、Android 0.3.0，均为开发测试版，未上架应用商店。源码仓库：[weq-devs/WeQ-Remote](https://github.com/weq-devs/WeQ-Remote)（私有，默认分支 `dev`）。

## 仓库边界

| 本仓库 | WeQ 桌面仓库 |
| --- | --- |
| iOS / Android 手机壳、协议客户端、原生网络与缓存 | Web 页面、业务 API、QQ 数据库和业务能力 |
| 扫码、设备凭据、证书校验、WebView、手机构建测试 | 配对批准与撤销、Web 服务、电脑网络入口、桌面协议夹具 |

单纯更新业务页面只需更新电脑提供的 Web；原生连接、权限、缓存或 WebView 改动才需要更新手机安装包。独立仓库不等于可以脱离电脑运行。

## 目录与构建

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

Android 的 Java 协议测试复用构建时校验的 ZXing 依赖；首次运行前按平台说明准备，不自动下载不明版本。SDK / 模拟器继续使用既有外盘与 guard 入口，不在 SSD 新建替代实例。

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

历史中的个人提交身份、本机路径及应用标识已脱敏；当前应用命名空间为 `io.github.weqdevs.remote`。这与旧身份安装是不同应用，不能原位升级或直接读取其 Keychain / Keystore；新构建需要单独安装并重新配对。本次仅清理源码，未构建、安装或迁移设备数据，现有版本号不代表已发布该身份变更。
