# 从 WeQ 拆分

迁移日期：2026-10-23（北京时间）。本仓库路径为 `/path/to/WeQ-Remote`；没有创建远端或上传。

## 来源与历史

- 来源仓库：`/path/to/WeQ`，迁移读取时的 HEAD 为 `85ffcee7894887c1c2d952f439e2969d492c6c34`。
- 通过 Git fast-export / fast-import 仅导入 `apps/ios`、`apps/android` 的路径历史；不是复制整个仓库，也没有改写来源历史。
- 路径过滤后提交 ID 会变化，对照如下：

| WeQ 原提交 | 本仓库提交 |
| --- | --- |
| `7d616683a160da86a939e9b5429bce5fa8a50046` | `9e3e8a2` |
| `bbf0f7622a42797cb5174dd36bdd78fe496a3a14` | `c122ff6` |
| `a7ae67a74dc45b8f66784e629a80a575d67d3aa9` | `40408e8` |
| `7889058dffa29a8b987345b6e31edddaebf1e69e` | `43579c8` |

导入后先提交手机目录当时的完整工作区快照，再另行提交路径和测试边界调整。来源仓库的其他未提交改动不纳入本仓库。

## 文件与运行数据

- 手机目录连同被忽略的 `.build`、本机生成工程原地移动，没有复制约 1 GiB 的构建缓存。
- 构建产物、测试状态和既有历史回执保留在原目录的对应新路径，不进入 Git；旧回执中的原始命令与路径作为历史证据保留，不逐条改写。
- 没有迁移或清除真机应用数据、Keychain / Keystore、电脑设备授权、桌面 userData 或外盘模拟器。
- 生成的 Xcode 工程与部分缓存包含旧绝对路径，迁移后重新生成工程；缓存不可复用时由构建工具正常重建，不用兼容软链接掩盖漏改。
- `scripts/remote-integration-server.ts`、其合成 Web 页面及 `tools/remote-network/ios-test-network` 归电脑侧测试，保留在 WeQ；手机测试通过显式桌面入口使用它们。

## 迁移后验证

- 本仓库边界与路径测试 4 项通过；覆盖显式桌面路径、带空格路径、缺失 / 错误仓库拒绝、手机源文件无桌面私有导入，以及产品构建不依赖桌面仓库。
- Swift 宿主机协议与非持久数据存储共 9 项测试通过；Android Go `test -race ./...`、Java 邀请 / 地址 / 凭据 / SHA-256 / 真实二维码编解码检查通过。
- 从新路径重新生成 Xcode 工程后，iOS 真机目标 Debug 编译通过（本轮未签名、未安装）；Android 从新仓库完整构建 APK，v2 / v3 签名校验通过，沿用本机测试签名。
- 通过 `WEQ_REMOTE_CLIENT_REPO=/path/to/WeQ-Remote node --test scripts/remote-integration-server.test.mjs`，实际从本仓库 Python 入口启动电脑夹具，验证契约版本、配对、批准、状态、Web / RPC 和撤销后的拒绝全部通过；没有读取真实 QQ。
- 桌面主进程 / preload / renderer 与 Web 在隔离输出目录编译通过；没有覆盖正在运行的 `out` / Web `dist/public`，没有重启桌面服务。隔离构建配置及日志在既有 `/path/to/private-maintenance/`，文件前缀 `remote-split-`。
- 本轮未启动模拟器、未重新安装真机、未修改设备凭据、未执行全仓 CI，也没有将构建成功冒称真机加载耗时或公共网络验收。
- 新仓库有本地提交、无远端。WeQ 原工作区中迁移产生的删除、夹具和文档调整保留待审，没有将其他任务的未提交改动连带提交。

