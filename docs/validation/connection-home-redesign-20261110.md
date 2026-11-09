# 连接首页三段式改版

日期：2026-11-10（北京时间）。源码版本：0.2.0 开发版，未发布。

## 改动

首页不再把标题、扫码入口和链接输入全部堆在顶部，改为全屏三段式：

- **顶部状态条**：小型品牌标记、“WeQ Remote”和连接状态胶囊（未连接 / 连接中 / 等待批准 / 正在进入 / 已连接）。只占一行，不再用 30pt 大标题压住页面。
- **中部状态区**：同心圆标记居中，下面按状态显示连接阶段、电脑地址、六位校验码或失败原因；加载时圆环内换成进度指示。
- **底部操作坞**：随状态切换“扫码连接”主按钮 + “粘贴配对链接”输入行，或“重新连接” + “删除电脑”。主操作贴近拇指，输入行自带箭头提交；最底部是网络状态和版本号两行小字（Android 从包信息读取 versionName，iOS 读 CFBundleShortVersionString）。

两端同步实现，颜色、间距和状态文案一致：iOS 用 SwiftUI，Android 用原生控件（`MainActivity` 首页布局重写，新增 `ic_link`、`ic_arrow_right` 两个矢量图标）。既有行为和标识保留：扫码、链接配对、`pairingLink` / `pairComputer` / `connectionProgress` / `connectionError` / `computerState` 无障碍标识、删除确认、网页全屏切换、加载阶段文案。

加载阶段细分（资源下载 / 初始化 / 恢复检查 / 绘制）沿用 2026-11-10 已提交的 `fix: 在连接首页显示网页初始化的具体进度`，本次只换承载它的版式。

顺带修掉两处旧问题：`pair()` 与 `restoreComputer()` 写入错误文案后没有触发重绘，错误行原本要等下一次状态更新才出现；Android 底部网络状态文案从内部用语“App 内网络”改为“网络”。

## 验证

- Android 测试包构建通过（`android-sdk-run python3 apps/android/scripts/build.py --test --skip-network`）。
- Android 专用 AVD（`WeQRemote_API36`，端口 5580）实际启动测试包截图四种状态：浅色未连接、深色未连接、粘贴链接并弹起键盘、无效链接的错误态。截图确认三段式排版、状态胶囊、主按钮、输入行、错误行与网络状态小字均正常；键盘弹起时操作坞仍在键盘上方，错误态标题切换为“连接未通过”。
- iOS Debug 模拟器构建通过（`xcodebuild -destination 'generic/platform=iOS Simulator'`）。
- **iOS 视觉未验收**：本机 `launchd_sim` 无法绑定启动会话（`Failed to start launchd_sim: could not bind to session`，多次重试、重启 CoreSimulator 服务与 SimLaunchHost 均失败），当前环境无法启动模拟器，也没有真机安装。iOS 只做到编译通过和按 Android 已验收的参数对齐，不能据此声称 iOS 界面已验证。
- 编译用的模拟器切片来自本机另一份同上游提交（`d1dc45d`）的 TailscaleKit 构建，临时合入 `.build` 缓存后已还原，未进入仓库，也不作为产品构建来源。
- 未重跑两端网络集成、配对与撤销流程；本次改动不触碰连接、协议和网页加载逻辑。

## 本地证据

截图在 `/tmp/weq-design/`（可再生产物，不入 Git）：`final-light.png`、`final-dark.png`、`final-typed.png`、`final-error.png`、`version-no.png`、`version-yes.png`；同一份副本在 `apps/android/.build/design/`。iOS 构建日志 `apps/ios/.build/design-build.log`，Android 构建日志 `/tmp/weq-design/android-test-build.log`。
