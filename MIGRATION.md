# 从 WeQ 拆分

WeQ Remote 于 2026 年 10 月 23 日从 WeQ 拆出。独立仓库导入 `apps/ios`、`apps/android` 的路径历史和拆分时的工作区快照。电脑端协议服务、网页和联调夹具仍在 WeQ，客户端通过明确的进程和 HTTP 入口联调。

当前应用标识为 `io.github.weqdevs.remote`。旧标识的安装需单独保留，新应用安装后重新配对。旧 Keychain／Keystore 数据和电脑原授权仍归原应用及原设备记录。

迁移 checkout 后重新生成 Xcode 工程。包含旧绝对路径的构建缓存由构建工具重建。
