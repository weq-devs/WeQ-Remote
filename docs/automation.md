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

构建脚本生成并校验 APK 的 v2 / v3 签名，使用 AAPT2 读取实际 APK 身份及版本，与源码清单比对后生成 `android-build.json` 来源记录。只上传 `.build` 根目录的 APK、`SHA256SUMS` 和该来源记录，显式启用 `include-hidden-files` 以允许隐藏父目录下的白名单路径；不递归上传整个 `.build`。Artifact 名含运行 ID 与重试次数，保留 3 天。不会上传 keystore、节点状态、完整构建缓存或用户配置；单独构建不会创建 GitHub Release、Tag 或商店发布。

每轮 runner 的 debug 签名是临时身份，不能保证跨次构建相同，也不能用于覆盖使用其他证书的既有安装。专用 `-test.apk` 含测试控制入口，不作为普通客户端交付。两类 APK 都是开发测试产物，不能作为正式签名或分发承诺。

## 依赖与权限

- 所有 Action 固定到完整提交 SHA，版本注释放在同一行；Dependabot 仅对 GitHub Actions 每周检查并向 `dev` 提出更新 PR，不自动合并、不自动升级协议依赖。
- CI 和构建 Job 的 `GITHUB_TOKEN` 仅有 `contents: read`；Release 的发布 Job 单独授予 `contents: write` 与 `actions: read`。checkout 不持久保存凭据。工作流不引用仓库 Secrets，不使用 `pull_request_target`、自托管 runner 或个人机器路径。
- ZXing 仅从固定 Maven Central 地址下载，版本为 3.5.3，最大 1 MiB；SHA-256 校验成功后原子保存。已有缓存损坏即失败，不覆盖或信任损坏文件。
- 手动 APK 工作流的真实执行结果见下方验收回执；本地语法 / 单测通过不等于云端构建已运行成功。

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

未签名 IPA 无法直接在普通 iPhone 上运行；安装前需要正确签名 App、内嵌 Framework 和 entitlements。单独运行该构建工作流不创建 Release、不上传 TestFlight、不操作设备；只有下方显式触发的 Release 工作流负责 GitHub 发布。整个 Job 超时 45 分钟，权限 / 并发取消策略与其他手动构建一致。

参考：[GitHub 工作流安全](https://docs.github.com/en/actions/reference/security/secure-use)、[Runner 镜像](https://github.com/actions/runner-images)、[setup-go 版本与缓存契约](https://github.com/actions/setup-go)。

## GitHub Release

当前源码为 iOS / Android 1.0.0b1（iOS 系统版本 1.0.0、build 8，Android versionCode 6），实际发布状态以 GitHub Releases 为准；以下历史构建回执保留原值。

`.github/workflows/release.yml` 只支持手动触发，且必须运行在已存在的 `vMAJOR.MINOR.PATCH` 或 `vMAJOR.MINOR.PATCHbN` 标签上（N 为不带前导零的正整数）；Beta 自动标记为 Pre-release，不替换 Latest 正式版。在分支上误触发会失败，不创建标签或发布。发布前先经用户授权提交并推送版本、文档及标签，再执行：

```sh
gh workflow run release.yml --ref v1.0.0b1
```

Release 复用同一标签提交的 CI、Android 普通 APK 和 iOS 未签名 IPA 工作流，各自使用独立并发组，避免可复用工作流相互取消。三个流程全部成功后，发布 Job 只下载当前运行 ID / attempt 的两端产物。`scripts/release_assets.py` 复核版本、SHA-256、干净源码提交、IPA 实际身份 / 真机二进制与两端来源记录；仅将普通 APK、未签名 IPA、两份来源记录和汇总 `SHA256SUMS` 作为附件。

iOS 的系统版本字段只允许数字和点，Beta 完整标识放在 `Support/Info.plist` 的 `WeQReleaseVersion` 中并用于应用内显示；打包来源记录同时保存 `version` 与 `releaseVersion`。发布时分别核对 IPA 的数字版本和完整标识，两者均须与标签匹配。

发布使用 `gh release create --verify-tag`，不会隐式新建标签，不覆盖已有 Release 或附件。GitHub CLI 先准备草稿并上传附件，全部成功后发布；失败不冒称已发布，不自动删除现场或重写标签。Release 附件不受 Actions Artifact 的 3 天保留期限制。源码构建、GitHub 发布不等于商店上架或签名安装，具体边界见 [0.1.0 发布说明](releases/0.1.0.md)。

## 验收边界

已提供 iOS 完整未签名 App 构建入口，但不提供正式签名或安装验收。真实电脑夹具集成、摄像头扫码、公共网络 / 蜂窝切换、Keychain / Keystore 持久化与长期耗电仍按平台说明单独验收。

工作流定义、本地验证、GitHub 已识别工作流、真实运行成功、可分发产物是不同状态，维护回执应分别记录。修改文件不会自动让未推送的工作流在 GitHub 上生效。

## 云端实跑回执（2026-10-23，北京时间）

经用户授权，将自动化提交推送到现有私有仓库 `dev`，首轮构建源码为 `52aa4d7e4f6e8d48a7e231c72fab2f8483f89321`；Android 上传修复及重跑源码为 `e85d7d96f1e7a4af18f409b9c882a5c812d6bc6a`。未创建 Release、Tag 或商店发布，未安装应用或操作设备。

- [日常 CI #39907358806](https://github.com/weq-devs/WeQ-Remote/actions/runs/39907358806)：三个 Job 全部成功，包括仓库 / Java 协议、Swift 宿主机协议、工作流校验及 Go 静态 / 竞态检查。
- [Android 首轮 #39907390364](https://github.com/weq-devs/WeQ-Remote/actions/runs/39907390364)：APK 编译、v2 / v3 签名校验及锁文件检查成功，但 Artifact 上传失败；上传 Action 默认排除隐藏文件，导致 `.build` 下白名单路径被过滤。本轮没有可下载的 Android Artifact，不能记作端到端通过。后续修复显式启用 `include-hidden-files`，仍保持原有 APK / 校验和白名单。
- [Android 修复后重跑 #39908423616](https://github.com/weq-devs/WeQ-Remote/actions/runs/39908423616)：13:55:10–13:59:06，Job 用时 3 分 56 秒，全部成功。仓库 / Java / Go 竞态测试、普通 APK 编译、签名校验、锁文件检查、校验和生成及 Artifact 上传均通过。该修复提交的[日常 CI #39908392409](https://github.com/weq-devs/WeQ-Remote/actions/runs/39908392409)也全部成功。
- Android Artifact 为 `android-development-39908423616-1`，仅包含 `weq-remote-0.3.0-arm64.apk` 和 `SHA256SUMS`。APK 为 0.3.0（versionCode 3），8,803,004 字节；下载后 SHA-256、ZIP 完整性和 v2 / v3 签名复核通过，包名为 `io.github.weqdevs.remote`，原生架构为 `arm64-v8a`，min / target SDK 为 26 / 36。本轮未启用 `build_test_apk`，未验收可选专用测试 APK 分支。
- [iOS unsigned IPA #39907390229](https://github.com/weq-devs/WeQ-Remote/actions/runs/39907390229)：13:44:03–13:46:00，Job 用时 1 分 57 秒，全部成功。22 项仓库 / 构建辅助测试、9 项 Swift 测试通过，固定源码 Framework、Release App、IPA 打包与 Artifact 上传成功。
- iOS Artifact 为 `ios-unsigned-39907390229-1`，包含 `weq-remote-unsigned.ipa`、`SHA256SUMS`、`build.json`。IPA 为 0.3.2（build 5），8,245,866 字节，来源记录 `sourceDirty: false`。下载后 SHA-256、ZIP 完整性、应用身份、主程序与内嵌 Framework 的无签名真机 arm64 检查均通过。

iOS IPA SHA-256：`af6efa2be2b35158da4cb36e0e162572c45c47448e8811b3e21db0428e4dbd6d`。

Android APK SHA-256：`324138c21aecd31174840ec714875040d2cc7947e85e4c77bc67c7a9bd77c616`。

本地下载及复核产物位于仓库内 `apps/ios/.build/actions/39907390229/` 与 `apps/android/.build/actions/39908423616/`，均为 Git 忽略的可再生产物，不入版本历史。

云端 Artifact 按工作流保留 3 天，不是永久下载入口。上述结果只证明对应提交的自动化测试、构建、打包和上传链路，不代表签名安装、真实网络或性能验收。

## 0.1.0 发布回执（2026-10-23，北京时间）

- 发布源码提交：`a03202c86acc9682972079c69ce3942febb4f749`，注释标签 `v0.1.0`。标签前的 [dev CI #39910581481](https://github.com/weq-devs/WeQ-Remote/actions/runs/39910581481) 全部通过。
- [Release #39910834092](https://github.com/weq-devs/WeQ-Remote/actions/runs/39910834092) 全部成功：标签与说明检查、三个 CI Job、两端构建、同轮产物来源 / 版本 / 摘要复核和自动上传发布均通过。iOS Job 用时 1 分 28 秒，Android Job 用时 5 分 43 秒。
- [WeQ Remote 0.1.0](https://github.com/weq-devs/WeQ-Remote/releases/tag/v0.1.0) 于 14:26:09 发布。API 复核 `isDraft: false`、`isPrerelease: false`，五个附件均为 `uploaded`；仓库仍为私有，未上架商店。
- Release 附件：普通开发签名 APK、未签名真机 IPA、`android-build.json`、`ios-build.json` 和汇总 `SHA256SUMS`。实际版本为 iOS 0.1.0（build 6）、Android 0.1.0（versionCode 4），两份来源记录均指向发布提交且 `sourceDirty: false`。
- 已将五个附件下载至仓库 `.build/releases/v0.1.0/`，汇总 SHA-256 全部通过；两安装包 ZIP 完整性、IPA 实际版本、APK 实际包身份 / 版本 / arm64 架构及 v2 / v3 签名复核通过。产物不入 Git，没有安装应用、操作设备或迁移凭据。

发布 APK SHA-256：`d0d791634f91de90c19285f10eb480d58e69e946b845ea1da1334b25e87c7425`。

发布 IPA SHA-256：`32558b7b834eeef0da4e3223956237bd2ed00f12cb5bce3235a725c68034077b`。

## 0.2.0 发布回执（2026-11-06，北京时间）

- 发布源码提交：`20b83d8bfe7c13823a1e1b8312b18cda16251c55`，注释标签 `v0.2.0`；版本号与构建号沿用源码现值，没有递增。
- 本地 34 项仓库及发布辅助测试、标签预检和差异检查通过；[dev CI #42086006966](https://github.com/weq-devs/WeQ-Remote/actions/runs/42086006966) 与标签 CI #42086006848 全部通过。
- [Release #42086037495](https://github.com/weq-devs/WeQ-Remote/actions/runs/42086037495) 首轮 CI 和 Android 构建成功，但 iOS 因 hosted runner 多次分配失败而取消；GitHub 提示 macOS arm64 容量紧张，未创建 Release。
- 完整重跑（attempt 2）中，仓库 / Java、Go 检查、Android APK 与 iOS IPA 构建均成功，iOS 构建内的 Swift 宿主机测试也通过。独立 Swift CI 仍在排队，约 10 分 49 秒后主动取消本轮；自动 publish 未执行成功，不能将这次工作流记为全绿。
- 下载 attempt 2 的两端产物，以 `scripts/release_assets.py prepare` 复核同一干净来源提交、版本、SHA-256、ZIP 完整性及 IPA 身份 / 无签名真机 arm64 结构，全部通过。随后使用 `gh release create --verify-tag` 手动发布同一标签及五个校验附件，没有改写标签或替换产物。
- [WeQ Remote 0.2.0](https://github.com/weq-devs/WeQ-Remote/releases/tag/v0.2.0) 于 03:05:31 发布。API 确认 `draft: false`、`prerelease: false`，五个附件均为 `uploaded`，服务端摘要与本地一致。iOS 为 0.2.0（build 7），Android 为 0.2.0（versionCode 5）。
- 本机备用未签名 IPA 也构建成功，但未用于 Release；发布的两端安装包均来自云端 attempt 2。没有安装应用或操作模拟器 / 真机。

发布 APK SHA-256：`a3c9ce8bbb2c38e70ade3a173acf6a47e44e20ee634239459888b3aeee0c172c`。

发布 IPA SHA-256：`9fe7c014b2d8b9e89750395bbf4a31167c366135651b99652c74d15558987079`。
