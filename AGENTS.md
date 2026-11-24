# WeQ Remote 开发约定

- 本仓库维护 iOS／Android 客户端、协议、网络与原生 WebView。聊天页面、业务 API、数据库、电脑授权与网络入口由 WeQ 维护。
- 修改前读[根 README](README.md)、[协议](docs/protocol.md)和对应平台说明（[iOS](apps/ios/README.md)／[Android](apps/android/README.md)）。优先复用现有实现。使用中文文档和 Conventional Commits 中文提交。
- 默认在当前分支本地提交。创建远端、推送、发布、委派或联系其他 Agent 需要用户授权。
- 每次生成新安装包前递增对应平台构建号。iOS 改 [project.yml](apps/ios/project.yml) 的 `CURRENT_PROJECT_VERSION`，Android 改 [AndroidManifest.xml](apps/android/AndroidManifest.xml) 的 `versionCode`。构建后核对产物。仅编译检查、复用或重传已有产物不递增。版本号只按用户明确指令修改。
- 按改动范围选最小充分验证。优先受影响模块的已有用例，Go 并发改动查竞态，平台集成改动做对应构建，复杂状态、协议与失败恢复按风险补回归。文案、图标、局部样式与入口增删通常检查差异即可。区分编译、安装、合成测试、真实网络及性能验收。
- 应用命名空间使用 `io.github.weqdevs.remote`。不引入个人域名或本机绝对路径。旧身份安装不自动迁移，测试不删除用户凭据或重置应用。
- 签名证书、描述文件、私有配置、运行身份、设备数据和构建目录不入 Git。原生依赖复用已有环境，避免复制整套依赖工程。
- 沿用外盘 SDK／模拟器及 `external_disk_guard`，通过 `android-sdk-run`、`ios-simulator-run` 或 `ios-simctl` 使用。使用外盘专用设备，结束后只关闭本轮设备。
- 联调用 `WEQ_DESKTOP_REPO` 指定 WeQ，通过明确的夹具入口调用。产品构建独立于桌面仓库，手机源码不导入桌面私有模块。
