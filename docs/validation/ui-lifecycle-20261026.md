# 连接页与前后台恢复验证

日期：2026-10-26（北京时间）。源码版本：0.2.0 开发版，未发布。

## 实现范围

- iOS / Android 调整原生连接页，保留扫码与链接两种入口；已保存电脑显示连接状态，不在自动恢复时闪出扫码表单。
- 已连接时保留网页与网络对象，后台停止原生重试；前台校验状态与授权。正常往返不主动刷新网页，暂时不可达时在原页面重试。
- Android 检查当前路由的本地网页代理是否仍有效，换路失效后重建网页入口；iOS 同入口恢复复用已有 WKWebView，仅换入口或网页进程被系统回收时重建 / 重载。
- Android 的前台连通性验证刷新 Java 网络接口快照，避免一直沿用退后台前的接口地址；此最后补充经构建验证，真实 Wi-Fi / 蜂窝切网仍未验收。
- 401 仍删除凭据并清空网页；手动断开与删除电脑继续有效。不新增后台服务、后台模式或保活权限，进程被系统回收后仅保证用保存的凭据尝试自动重连，不保证网页临时状态。

## 已通过

- Swift 宿主机协议与内存数据存储：12 项测试。
- Go 网络模块：`go test -race -p 2 ./...`，包含同路由验证保留代理、切换路由识别旧代理失效、授权失败不换路等反例。
- Java 协议 / 二维码测试。
- 仓库 Python 测试：29 项。版本校验测试改用隔离版本夹具，并验证缺少发布说明时拒绝发布；开发版无需伪造正式发布说明。
- Android 0.2.0 普通包与独立测试包构建、APK v2 / v3 签名校验。
- Android 专用模拟器的浅 / 深色两轮 LAN TLS 集成：真实电脑夹具配对、HTTP、WebSocket、Home 后返回同一个 WebView、保留 DOM 标记、不新增配对、Keystore 冷启动恢复、撤销授权与删除凭据。首次在撤销状态的等待边界失败，修正最后一次状态读取和等待窗口后两轮重跑通过。
- iOS Simulator Debug 与 iPhoneOS 未签名构建；检查连接页浅 / 深色截图。Android 最后的图标替换另经构建，截图可见图标已渲染，但该次启动被 Launcher / Digital Wellbeing / System UI 的 ANR 依次遮挡，不算完整视觉验收，也不冒称重新跑过完整网络集成。

## 未通过与限制

- iOS `testLANBackgroundResume` 未运行成功：CoreSimulator 无法绑定启动会话，Xcode 随后在打包变化中的诊断日志时崩溃。未将测试启动或编译成功计为 UI 测试通过。
- 外盘临时设备的 LAN 网页 smoke 首轮在配对阶段超时，第二轮结果为网页检查失败，未完成具体失败点定位，不能确认同 WKWebView / DOM 保留断言通过。电脑侧同一入口的 `/v1/hello` 可响应，尚不足以证明模拟器端连通，未据此宣布 iOS 网络恢复验收通过，也未将该失败确定归因为环境。
- 两端新增的回归断言已保留；iOS 实际后台往返、真实手机、公共 Tailscale、蜂窝切网、长期后台与耗电仍需后续实测。

## 本地证据

构建、测试日志和截图位于各平台 `.build/`，为可再生产物，不进入 Git：

- Android：`resume-build.log`、`resume-production-build.log`、`integration.log`、`pairing-light.png`、`pairing-dark.png`、`lan-connected-light.png`、`lan-connected-dark.png`。
- iOS：`resume-build.log`、`resume-device-build.log`、`resume-test-build.log`、`resume-uitest.log`、`pairing-light.png`、`pairing-dark.png`。

仅操作本轮专用模拟器与测试包；临时 iOS 设备正常关闭后删除，不保留其凭据。未安装到真实手机，未发布 Release。
