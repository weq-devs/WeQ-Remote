# WeQ Remote for Android

当前源码为 0.2.0（versionCode 5）。Android 8.0 / API 26 起，当前仅构建 arm64-v8a。见 [0.2.0 发布说明](../../docs/releases/0.2.0.md)，实际发布状态以 GitHub Releases 为准。

手机端仅封装电脑提供的 WeQ Web 和内嵌 TS，首页只保留扫码和链接输入。支持局域网 HTTPS 指纹配对或一次性 Auth Key 扫码入网，不占用系统 VPN。手机壳已独立仓库，协议见[协议约定](../../docs/protocol.md)，本机电脑侧用法见 [Web 与手机连接](../../../WeQ-upstream/docs/guide/remote-web.md)。

## APK 与使用

开发 APK：`/path/to/WeQ-Remote/apps/android/.build/weq-remote-0.2.0-arm64.apk`。
这是本机测试签名，不是商店正式发布。`-test.apk` 是独立包名的自动化测试版本，不作为普通客户端交付。

1. 安装普通 APK；新版电脑并列显示局域网与 WeQ 专用 Tailscale 地址，统一点击「生成配对码」。跨网络时启动并登录专用 Tailscale，勾选「嵌入 Tailscale Key」，点击生成后在弹窗填写 Key。
2. 扫描电脑配对码，或复制电脑端的配对链接后粘贴。
3. 扫码直接发出请求，粘贴链接后点连接；电脑弹窗批准一次。
4. 网页完成恢复检查、账号探测、必要配置及真实界面绘制后全屏进入 WeQ Web，不显示原生工具栏或按钮。准备期间首页显示资源下载、网页初始化、恢复检查和界面绘制等具体阶段；会话和好友等业务列表在正式界面内加载，不阻塞启动。HTML 加载完成不会提前切页；失败或 45 秒超时在首页重试，需要同步更新电脑网页。需要确认的恢复回执会显示操作页面。网页 HTTP 与 WebSocket 均经选定连接路径。
5. 新版网页顶栏的连接菜单可重新加载或断开；断开保留电脑，首页点击「重新连接」恢复。首页删除电脑需要确认，删除后可扫描另一台电脑。系统返回优先退回网页上一级，顶层交给系统处理，不自动断开。

开发源码接入网页文件选择（含多选和取消）、麦克风/摄像头系统授权、外链跳转、
鉴权文件下载与网页生成的 Blob 文件下载。保存时选择系统文件位置，不申请整个存储空间访问。
网页菜单截图先生成当前 WebView 的 PNG，再打开保存位置；取消或中断会清理本轮暂存。
下载不将鉴权 Cookie 交给外部应用，不跟随下载重定向；媒体只向当前电脑页面的已知音视频资源授权。
这些入口尚待真实 Android 手机验收，不包含手机屏幕共享、原生推送或后台持续通话。

设备令牌通过 Android Keystore 的 AES-GCM 密钥加密保存，禁止备份。已连接时退后台暂停 WebView 并停止原生重试，不销毁网页或本地代理；返回前台校验授权，短暂断网保留页面并重试。Activity 销毁时释放网络，进程回收后的冷启动使用保存的凭据自动重连，不重新配对；不使用前台服务或后台保活，不承诺进程被回收后恢复网页临时状态。401 撤销授权仍清除凭据。TS 身份保存在私有 no-backup 目录；原始入网 Key 不落盘。局域网走系统路由并校验证书 SHA-256 指纹，系统 Tailscale 可达时不需要内嵌节点。

当前开发源码新增 v4 多入口邀请，保存全部入口，连接时错峰探测并采用首个可用入口，不逐个等待不可达地址超时；已配对设备恢复连接时的探测即一次鉴权状态读取，成功结果直接用于本次连接，不再重复核验，也不另设更短的探测硬超时。内嵌入网不再阻塞可用的 HTTPS 直连，直连胜出时不会用未完成的节点替换保存的入网身份。首次配对先探测再提交一次配对申请，不跨路径重发 POST。已发布的 0.1.0 尚不支持 v4，需要新版 App；旧 v1/v2/v3 邀请继续可用。

## 构建

使用 Java 原生控件、标准 Android SDK 构建工具与固定版本 gomobile，不需要新下载 Android Studio 或 Gradle。网络模块独立维护 `network/go.mod` / `go.sum`，不升级电脑端依赖。

本机工具：Go 1.27.2、JDK 17、SDK/API 36、Build Tools 36.0.0、NDK 28.2.13676358。
`ANDROID_HOME` / `ANDROID_NDK_HOME` 可覆盖默认 SDK/NDK 路径。

```sh
cd /path/to/WeQ-Remote
android-sdk-run python3 apps/android/scripts/build.py
android-sdk-run python3 apps/android/scripts/build.py --test --skip-network
bash apps/android/scripts/check-protocol.sh
cd apps/android/network
go test -p 2 ./...
```

首次构建下载小型 Go 工具和固定的 ZXing 3.5.3 JAR，复用本机 SDK 与系统镜像；不下载整套 IDE。`scripts/dependencies.py` 为构建和 Java 测试提供同一个 SHA-256 校验入口；协议测试不要求先构建 APK，不需要 SDK / NDK。APK 包含 Go/TS 依赖的许可证文本。测试签名密钥按 Android 惯例保存在 `~/.android/debug.keystore`，不进仓库。

GitHub Actions 的 `Android development APK` 支持手动构建 arm64 普通 APK，并可选另建专用测试 APK。标签上的 `Release` 工作流只发布普通 APK，不发布专用测试包。产物、签名与自动验收边界见[自动化维护](../../docs/automation.md)；云端临时 debug 签名不能代替既有安装的签名。

## f 盘模拟器

本轮独立 AVD：`WeQRemote_API36`，端口 5580。
用户数据：`/Volumes/External/Runtime/WeQRemote/android/avd/WeQRemote_API36.avd`。
只读系统镜像复用本机现有 `system-images;android-36;google_apis;arm64-v8a`；没有再复制一份 SDK 镜像。已有的其他 AVD 不动。

启动脚本先实时检查 Volume UUID 与真实挂载点，再核对 AVD 注册入口，最后接统一 `external_disk_guard.py`。缺盘、UUID 不匹配不创建 SSD 替代目录；hold 由统一 guard 停止外盘 I/O。cwd 始终留在本机项目。

```sh
diskutil info -plist '/Volumes/External'
# 使用实时核实的 VolumeUUID；本轮 AVD 已创建，不必再次 --create。
python3 apps/android/scripts/emulator.py \
  --volume '/Volumes/External' --uuid '<实时核实的VolumeUUID>'
```

配置为无窗口、无音频、禁快照、2 核。SDK 会将 Android 36 的 RAM 最小值提升为约 2.5 GB。首次启动需要完成系统初始化；测试后正常关闭本轮设备：

```sh
android-sdk-run adb -s emulator-5580 emu avd name
android-sdk-run adb -s emulator-5580 emu kill
```

## 真实 TS 集成验证

```sh
android-sdk-run python3 apps/android/scripts/integration.py \
  --desktop-repo /path/to/WeQ --serial emulator-5580
```

脚本通过 `--desktop-repo` 或 `WEQ_DESKTOP_REPO` 定位电脑侧夹具；缺少约定入口时明确失败，不从手机模块导入桌面私有实现。它仅接受 `WeQRemote_API36`；复用本机测试控制面、DERP、正式电脑端网络辅助程序和真实配对接口，不登录公共 tailnet。ADB reverse 只用于让模拟器访问本机测试控制面与中继；App 的 `/v1/pair`、`/v1/status` 实际经过内嵌 TS，不改走系统 HTTP 冒充加密通道。

自动检查默认不启动网络、配对、实际状态读取、重复请求、撤销后的 401，并检查浅/深色。专用 `io.github.weqdevs.remote.test` APK 才启用回环测试控制面与测试 instrumentation；普通 APK 不接收这些测试 Intent 参数，也不允许系统明文 HTTP。

截图前必须确认活动窗口属于测试 App，防止被系统对话框遮挡时仍把功能断言冒称完整界面验收。

测试截图与日志保存在 `.build/connected-light.png`、`.build/connected-dark.png`、`.build/integration.log`。脚本结束清理本轮测试服务和反向端口；模拟设备由操作者按上节正常关闭。日志不记录邀请、访问令牌或节点身份密钥。

真实手机的相机、公共控制面登录、跨公网/蜂窝切网及长期耗电需另外验收，不能用本机模拟器结果代替。

## 0.1.0 历史验证回执（2026-10-22）

- 普通版与专用测试版均构建成功，APK v2 / v3 签名校验通过，普通版约 8.4 MiB；版本为 0.1.0，本机测试签名，未上架。
- 普通交付 APK 已实际安装、冷启动检查通过；默认网络未启动，无测试标记、无系统遮挡，清单无测试 instrumentation 且不允许系统明文 HTTP。
- Go 桥接的 4 项离线单元测试通过；Java 邀请、目的地址、重复字段、随机凭据、哈希兼容性及真实二维码编码/解码检查通过。
- Android 16 / API 36 arm64 专用模拟器：浅色、深色两轮原生 instrumentation 通过。实际经过手机内嵌 TS → 本地直连/DERP → 正式电脑网络辅助程序 → 真实配对及状态 API，重复请求和撤销后的 401 均通过。活动窗口检查通过，截图无系统遮挡，不是手填假在线状态。
- 首轮发现 JNI 进程缺少安全日志状态目录导致 SDK panic，已固定到 App 私有 no-backup 目录，并补充离线回归。日志上传仍关闭。
- 虚拟机冷启动曾出现系统/系统 UI 未响应对话框；已正常清除、改用宿主 GPU、关闭本测试设备的蓝牙和动画，并在加入可见窗口检查后重跑通过。被遮挡的早期截图不作为交付。
- 初次冷编译已完成，后续复用 SDK、系统镜像和 Go 缓存；未升级电脑端 Go 依赖，未改动其他 AVD、LidAwake 或现用服务。
- 本轮测试进程、反向端口及专用测试包已清理，普通版保留在本项目 AVD 便于后续复测；模拟设备已正常关闭。未跑全仓 CI。

本轮交付 APK 的 SHA-256：`68b6668617ce6c2be3348c50f1222b1b8059000f7004ae70b5060a5bc4c311fe`。

构建输出和测试图为可再生产物，不进 Git。真实手机、相机和公网链路尚未验收。

依赖：[Go Mobile](https://go.dev/wiki/Mobile)、[Tailscale tsnet](https://pkg.go.dev/tailscale.com/tsnet)、[ZXing](https://github.com/zxing/zxing/tree/zxing-3.5.3)。
