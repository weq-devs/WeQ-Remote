# 自动化维护

## 日常 CI

[CI 工作流](../.github/workflows/ci.yml)在 push、pull request 和手动触发时运行。检查包括 Python 仓库与构建辅助测试、Java 协议及二维码往返、Go 模块校验／vet／竞态、工作流校验以及 Swift 宿主机测试。Swift 宿主机测试无需签名、TailscaleKit 或模拟器。完整 App 和设备联调按 [iOS](../apps/ios/README.md#验证)／[Android](../apps/android/README.md#验证)说明执行。

## 手动构建安装包

```sh
gh workflow run android-build.yml --ref dev
gh workflow run android-build.yml --ref dev -f build_test_apk=true
gh workflow run ios-unsigned.yml --ref dev
```

| 工作流 | 产物与检查 |
| --- | --- |
| [Android development APK](../.github/workflows/android-build.yml) | 普通 arm64 APK、实际身份及版本、v2／v3 签名校验、来源记录和摘要。可选另建专用测试 APK，复用同轮 AAR。runner 使用临时 debug 签名。 |
| [iOS unsigned IPA](../.github/workflows/ios-unsigned.yml) | 从固定上游和仓库补丁构建 TailscaleKit。IPA 内的 App 和 Framework 校验为无签名真机 arm64，附来源记录和摘要。 |

Actions Artifacts 名含运行 ID 与重试次数，保留 3 天。正式下载入口由下方 Release 工作流生成。

## GitHub Release

准备对应的 `docs/releases/<版本>.md`，它会成为 GitHub Release 正文。版本标签须在 GitHub 上已存在，格式为 `vMAJOR.MINOR.PATCH` 或 `vMAJOR.MINOR.PATCHbN`（N 为不带前导零的正整数）。经用户授权后，用下列命令在标签上手动触发。

```sh
gh workflow run release.yml --ref '<版本标签>'
```

[Release 工作流](../.github/workflows/release.yml)要求标签对应的 CI 与两端构建成功。发布任务仅取同一运行及重试轮次的产物。[校验脚本](../scripts/release_assets.py)核对干净源码提交、实际版本与 SHA-256，并检查 IPA 身份及真机二进制。iOS Beta 的数字系统版本与 `WeQReleaseVersion` 分别校验。

发布附普通 APK、未签名 IPA、两份来源记录和 `SHA256SUMS`。Beta 标签作为 Pre-release 发布，保留 Latest 正式版。已有 Release 和附件不覆盖。设备签名与真机验收按平台说明执行。

工作流依赖以完整提交 SHA 固定，由 [Dependabot](../.github/dependabot.yml)向 `dev` 提议更新。CI 和构建使用 `contents: read`，发布任务单独获得 `contents: write` 与 `actions: read`。
