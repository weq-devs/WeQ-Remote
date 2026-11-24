# WeQ Remote

WeQ Remote 是 WeQ 的 iOS／Android 客户端。手机负责扫码、连接和原生 WebView，聊天页面、业务功能和设备授权由电脑上的 WeQ 提供。

## 安装与连接

- **Android 8.0 及以上**使用 arm64 APK。覆盖安装要求新旧 APK 的签名一致。
- **iOS 17 及以上**使用真机 arm64 IPA。发布的 IPA 为未签名包，安装前须正确签名 App 与内嵌 Framework。

下载 [GitHub 最新正式版](https://github.com/weq-devs/WeQ-Remote/releases/latest)。当前开发内容见 [更新记录](CHANGELOG.md)。

1. 在电脑的「设置 → WeQ 服务 → Web 与 Remote」开启「允许远程连接」，生成配对码。
2. 手机扫码或粘贴配对链接，在电脑核对校验码并批准。后续可用已保存的授权连接。
3. 跨网络连接可使用 WeQ 内嵌的 Tailscale。电脑侧的入网、配对与撤销步骤见 [Web 服务与手机连接](https://weq-devs.github.io/WeqDocs/guide/remote-web)。

### 连接与本机缓存

电脑地址或入网 Key 变化时，可从「连接」旁的扫码入口更新资料，继续使用原有配对。

从 1.1.0 Beta 1 起，「连接」会打开电脑当前版本的网页。已有网页缓存时，首页的「直接进入本地缓存界面」可查看已保存的内容，等需要同步时再连接。网页中的「⋯」可重新连接、断开和管理启动时自动连接。错误页的「重新加载」只重载当前页面。

## 开发

原生构建只需本仓库和对应平台工具链。电脑端 WeQ checkout 仅用于联调。

| 文档 | 内容 |
| --- | --- |
| [iOS](apps/ios/README.md) | Xcode 构建、签名、SideStore 与测试 |
| [Android](apps/android/README.md) | APK 构建、专用模拟器与测试 |
| [协议](docs/protocol.md) | 配对、选路、网页桥与缓存 |
| [自动化](docs/automation.md) | CI、安装包构建与 GitHub Release |
| [应用图标](resources/brand/README.md) | 源图和生成命令 |
| [迁移记录](MIGRATION.md) | 拆仓历史与旧应用身份 |

源码沿用 WeQ 的 [许可证](LICENSE)。第三方依赖使用各自的许可证，包括 [Tailscale](apps/ios/Support/Tailscale-LICENSE.txt) 和 [Lucide](apps/android/Support/Lucide-LICENSE.txt)。
