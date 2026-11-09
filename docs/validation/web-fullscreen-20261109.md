# 已连接网页全屏与连接页加载进度

日期：2026-11-09（北京时间）。源码版本：0.2.0 开发版，未发布。

## 实现范围

- iOS 与 Android 的已连接网页在首次加载完成后铺满整屏：不显示原生导航栏、工具栏或悬浮按钮；系统状态栏与手势区域由页面自身的 `env(safe-area-inset-*)` 处理（iOS 关闭 WebView 自动内边距；Android 从 Chromium 136 起全屏 WebView 可透传安全区，旧内核由原生 padding 兜底）。
- 网页加载完成前不出空白全屏页，而是留在连接页（扫码连接页）用原生进度条/转圈和阶段文字显示「正在连接电脑」「等待电脑确认」「正在加载 WeQ 页面」。
- iOS 由 WKWebView 加载完成回调切换；Android 先把连接页叠在网页上，`onPageFinished` 后移除。加载失败时留在连接页并给出错误，保留重新连接入口。
- 本轮不提供网页内的断开、重新加载、删除电脑入口，下一轮再设计「更换 / 重新连接设备」。

## 验证

- iOS：用 iPhoneOS 17 SDK 对 Sources 全量类型检查（TailscaleKit 用本机替身，仅验证语法与类型），通过；Swift 宿主机协议测试 21 项通过。
- Android：完整构建通过（Go/gomobile 绑定、Java 编译、APK v2/v3 签名校验），Java 协议/邀请测试与仓库 Python 测试 34 项通过。
- Android 专用模拟器 LAN 集成（浅色 / 深色两轮）在最终源码上通过：配对、Keystore 冷启动恢复、网页 HTTP 与 WebSocket、撤销后清凭据。截图 `lan-connected-light/dark.png` 显示网页铺满整屏、无原生工具栏或按钮，状态栏与手势区域由页面/系统处理；`pairing-dark.png` 显示连接页在 edge-to-edge 下正常排版。`pairing-light.png` 被系统 System UI ANR 弹窗遮挡，属模拟器环境噪声，未据此判定界面。

## 未覆盖

- iOS 未在模拟器或真机构建；全屏效果、加载切换、安全区、深浅色与 VoiceOver 仍需真机验收。
- Android 旧版 WebView（Chromium < 136）的原生 padding 兜底、键盘避让与长时间后台仍未覆盖；本轮截图未捕捉到加载中的连接页进度态。
