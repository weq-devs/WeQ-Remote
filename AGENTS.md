# WeQ Remote 开发约定

- 本仓库只维护 iOS / Android 手机连接壳、协议客户端、网络与原生 WebView；聊天页面、业务 API、数据库、电脑端授权和网络入口仍由 WeQ 维护。
- 默认留在当前分支，本地提交，不自动创建远端、推送或发布。未获用户授权不委派、不联系其他 Agent。
- 修改前先读根 README、对应平台 README 和 `docs/protocol.md`，复用已有实现；中文文档与提交信息，Conventional Commits。
- 日常验证按改动范围执行：Swift 宿主机单测、Go 单测与竞态检查、Java 协议测试；原生变化另做对应平台构建。不得把编译、安装或合成协议测试冒称真实网络及性能验收。
- 使用项目命名空间 `io.github.weqdevs.remote`，不引入个人域名或本机绝对路径。旧身份安装不自动迁移；不为测试删除用户凭据或重置应用。
- 签名证书、描述文件、私有配置、运行身份、设备数据、构建目录不入 Git。原生产物及环境复用现有依赖，不复制整个依赖工程。
- 模拟器 / SDK 外盘约定继续有效，使用 `android-sdk-run`、`ios-simulator-run`、`ios-simctl` 及 external_disk_guard；不启动默认 SSD 设备，不关闭其他任务设备。
- 集成测试通过 `WEQ_DESKTOP_REPO` 选择桌面仓库，仅调用其明确的夹具入口，不从手机代码直接导入桌面私有源码。产品构建不依赖桌面仓库。

