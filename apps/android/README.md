# WeQ Remote for Android

支持 Android 8.0／API 26 及以上，构建目标为 arm64-v8a。安装和配对见[项目首页](../../README.md#安装与连接)。

## 构建 APK

使用 JDK 17、Android SDK 36、Build Tools 36.0.0、NDK 28.2.13676358 和 [Go 模块](network/go.mod)要求的工具链。使用 `ANDROID_HOME`／`ANDROID_NDK_HOME` 指定 SDK 和 NDK。本机通过 `android-sdk-run` 复用已配置的环境。依赖由脚本准备，ZXing JAR 与 Java 测试共用同一个 SHA-256 校验入口。

生成安装包前按[仓库约定](../../AGENTS.md)递增 Android 构建号。以下构建命令均从仓库根目录运行。

```sh
android-sdk-run python3 apps/android/scripts/build.py
```

普通版输出到 `apps/android/.build/weq-remote-<版本>-arm64.apk`，使用本机 `~/.android/debug.keystore` 签名。联调另建 `-test.apk`（应用标识 `io.github.weqdevs.remote.test`），自动化测试入口只编入该包。已有对应 AAR 时加 `--skip-network` 复用。

```sh
android-sdk-run python3 apps/android/scripts/build.py --test
```

云端构建见[自动化](../../docs/automation.md)。

## 验证

Java 协议和二维码测试无需 APK 或 SDK。Go 改动按影响范围选对应模块用例。

```sh
bash apps/android/scripts/check-protocol.sh
go -C apps/android/network test ./...
```

### 专用模拟器与联调

使用外盘上的 `WeQRemote_API36`（端口 5580），复用 `system-images;android-36;google_apis;arm64-v8a`。将下列挂载点及 UUID 换为实盘信息。已有设备可直接启动，新建时用同一脚本加 `--create`。

```sh
diskutil info -plist '/Volumes/<实际挂载点>'
android-sdk-run python3 apps/android/scripts/emulator.py \
  --volume '/Volumes/<实际挂载点>' --uuid '<VolumeUUID>'
```

准备专用测试 APK 和已安装依赖的 [WeQ 电脑仓库](../../docs/protocol.md#联调夹具)。脚本自行启动夹具。默认测试隔离 Tailscale，先准备电脑网络助手。加 `--lan` 可直接测试局域网 TLS 与持久重连。两种模式均检查配对、Web／WebSocket 与撤销。

```sh
export WEQ_DESKTOP_REPO=/path/to/WeQ
node "$WEQ_DESKTOP_REPO/scripts/prepare-remote-network.mjs"
android-sdk-run python3 apps/android/scripts/integration.py \
  --desktop-repo "$WEQ_DESKTOP_REPO" --serial emulator-5580
```

截图与日志在 `apps/android/.build/`（如 `connected-light.png` 和 `integration.log`）。若截图用于视觉验收，先确认活动窗口属于测试 App。脚本清理本轮夹具及 ADB 反向端口，测试结束后先核对设备名称，再关闭本轮模拟器。

```sh
android-sdk-run adb -s emulator-5580 emu avd name
android-sdk-run adb -s emulator-5580 emu kill
```
