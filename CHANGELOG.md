# 更新记录

## Unreleased - 进行中

- 支持新版电脑的 v4 多入口配对码，保存局域网与 WeQ 专用 Tailscale 入口，连接不可达时按顺序重连；兼容旧邀请，入网 Key 不随电脑凭据保存。
- 添加手动 iOS 未签名 arm64 IPA 工作流：校验固定上游源码与 XcodeGen，应用日志隐私补丁，从源码构建真机 TailscaleKit；隔离工程构建、无签名 / 平台 / Payload 校验、产物校验和与来源记录，不使用个人签名或私人依赖路径。
- 添加 GitHub Actions 日常 CI、手动 Android 开发 APK 构建与短期校验产物；固定 Action 提交，使用只读权限和并发取消，Dependabot 每周检查 Action 更新。
- Java 协议测试可独立准备带 SHA-256 校验的固定 ZXing 依赖，不再要求先在本机构建 APK；补充损坏缓存、下载失败和大小限制回归测试。
- 从 WeQ 拆出独立的 iOS / Android 手机连接客户端仓库，保留源码演进；业务网页与电脑授权仍由 WeQ 提供。
- 集成测试改用明确的电脑侧夹具入口，手机产品构建不依赖 WeQ checkout。
- 隐私清理：重写个人提交身份与本机路径，移除个人安装回执；应用标识改为 `io.github.weqdevs.remote`，不兼容旧身份安装的原位升级或凭据读取。未发布新应用，后续分发前须确定迁移与版本策略。
