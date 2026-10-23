# 自动化维护

## 日常 CI

`.github/workflows/ci.yml` 在所有分支 push、pull request 和手动触发时执行：

| Job | Runner | 验证内容 |
| --- | --- | --- |
| Repository and Java protocol | Ubuntu 24.04 | Python 仓库边界 / 应用身份 / 依赖准备回归，Java 邀请与真实二维码往返 |
| Go network and workflow validation | Ubuntu 24.04 | Actionlint 1.7.12、Go 模块校验、vet、race 测试、锁文件未变化 |
| Swift host protocol | macOS 15 | `Package.swift` 声明的宿主机协议与 Web 数据存储测试 |

Go 版本读取 `apps/android/network/go.mod`，缓存以 `go.sum` 为键；Java 为 Temurin 17，Python 为 3.13。Go 依赖使用只读模块模式，测试不连接公共 tailnet，不读取真实聊天或设备授权。

Swift Job 不依赖定制 TailscaleKit、开发签名、桌面仓库或模拟器，只编译 Swift Package 中显式列出的文件；不能替代整个 iOS App 的原生构建或 UI 测试。

同一分支 / PR 的新运行会取消旧运行；三个 Job 分别有 10 / 20 / 15 分钟超时。当前没有修改仓库分支保护或自动合并设置。私有仓库运行受组织 Actions 额度限制，排队 / 额度不足与测试失败应分别记录。

## 手动 Android APK

在 Actions 选择 `Android development APK`，运行目标分支；可选 `build_test_apk`，默认只构建普通版。CLI 等价入口：

```sh
gh workflow run android-build.yml --ref dev
gh workflow run android-build.yml --ref dev -f build_test_apk=true
```

工作流在 Ubuntu 24.04 中准备 API 36、Build Tools 36.0.0、NDK 28.2.13676358，不安装模拟器镜像。先运行仓库 / Java / Go race 测试，再调用现有 `apps/android/scripts/build.py`；可选测试版复用本轮生成的网络 AAR。整个 Job 超时 45 分钟。

构建脚本生成并校验 APK 的 v2 / v3 签名。只上传 `.build` 根目录的 APK 和 `SHA256SUMS`，Artifact 名含运行 ID 与重试次数，保留 3 天。不会上传 keystore、节点状态、完整构建缓存或用户配置，也不会创建 GitHub Release、Tag 或商店发布。

每轮 runner 的 debug 签名是临时身份，不能保证跨次构建相同，也不能用于覆盖使用其他证书的既有安装。专用 `-test.apk` 含测试控制入口，不作为普通客户端交付。两类 APK 都是开发测试产物，不能作为正式签名或分发承诺。

## 依赖与权限

- 所有 Action 固定到完整提交 SHA，版本注释放在同一行；Dependabot 仅对 GitHub Actions 每周检查并向 `dev` 提出更新 PR，不自动合并、不自动升级协议依赖。
- `GITHUB_TOKEN` 仅有 `contents: read`，checkout 不持久保存凭据。工作流不引用仓库 Secrets，不使用 `pull_request_target`、自托管 runner 或个人机器路径。
- ZXing 仅从固定 Maven Central 地址下载，版本为 3.5.3，最大 1 MiB；SHA-256 校验成功后原子保存。已有缓存损坏即失败，不覆盖或信任损坏文件。
- 手动 APK 工作流上线后首次执行仍需观察 SDK、gomobile 与 runner 平台兼容情况；本地语法 / 单测通过不等于云端构建已运行成功。

## 手动 iOS 未签名 IPA

Actions 选择 `iOS unsigned IPA`，或执行：

```sh
gh workflow run ios-unsigned.yml --ref dev
```

工作流使用 macOS 26、固定的 Go 1.27.2 与 XcodeGen 2.46.0，不访问证书、Apple ID、描述文件或仓库 Secrets。XcodeGen 发布 ZIP 用 SHA-256 校验，Tailscale 源码压缩包按固定 commit 与 SHA-256 校验。

`apps/ios/scripts/build_tailscale.py` 从源码构建真机 arm64 Framework；固定上游已提供 `statusJSON()`。仓库内隐私补丁关闭日志上传 / 支持报告和入网用户日志，App 自身继续使用静默日志接收器。只构建真机，不下载模拟器运行时，也不从个人工程复制 Framework。Go 依赖遵循上游 `go.mod` / `go.sum` 的只读模式。

`apps/ios/scripts/build_unsigned_ipa.py` 以 `CODE_SIGNING_ALLOWED=NO`、空签名身份和团队编译 Release。它使用隔离生成工程，不覆盖现有工程；校验主程序与内嵌 Mach-O 均为无签名的真机 arm64，拒绝描述文件 / 签名材料和逃出 App 的符号链接，然后生成 `Payload/WeQRemote.app` 布局的 IPA。

仅上传未签名 IPA、`SHA256SUMS`、`build.json`，保留 3 天。来源记录含源码提交 / dirty 状态、依赖校验和、补丁校验和、工具链与产物摘要，不含个人路径、签名身份或认证。Xcode patch / runner 镜像可更新，因此“固定来源与可重复入口”不等于跨工具链二进制逐字节一致；使用来源记录核对每次构建。

本地入口与云端相同：

```sh
python3 apps/ios/scripts/build_unsigned_ipa.py
```

未签名 IPA 无法直接在普通 iPhone 上运行；安装前需要正确签名 App、内嵌 Framework 和 entitlements。没有自动发布、上传 TestFlight、创建 Release 或操作设备。整个 Job 超时 45 分钟，权限 / 并发取消策略与其他手动构建一致。

参考：[GitHub 工作流安全](https://docs.github.com/en/actions/reference/security/secure-use)、[Runner 镜像](https://github.com/actions/runner-images)、[setup-go 版本与缓存契约](https://github.com/actions/setup-go)。

## 验收边界

已提供 iOS 完整未签名 App 构建入口，但不提供正式签名或安装验收。真实电脑夹具集成、摄像头扫码、公共网络 / 蜂窝切换、Keychain / Keystore 持久化与长期耗电仍按平台说明单独验收。

工作流定义、本地验证、GitHub 已识别工作流、真实运行成功、可分发产物是不同状态，维护回执应分别记录。修改文件不会自动让未推送的工作流在 GitHub 上生效。
