# 电脑与手机的协议边界

本文件描述当前两边已经实现的契约，不是新增一套协议。权威实现分别位于 WeQ 的 `apps/desktop/src/main/remote` 与本仓库两平台的协议客户端；任一侧变更均需运行另一侧能推翻兼容假设的反例测试。

## 邀请版本

共同格式为 `weq-remote://pair`，查询字段不重复、不接受未知字段，不携带 URL 用户名、密码、路径或 fragment。

| `v` | 字段 | 传输 |
| --- | --- | --- |
| 1 | `v, endpoint, invitation` | 内嵌 TS 的 `http://100.64.0.0/10:<port>` |
| 2 | v1 字段加 `authKey, expiresAt` | 内嵌 TS；Auth Key 仅用于本次入网，过期字段为毫秒时间戳 |
| 3 | `v, endpoint, invitation, fingerprint` | 私有 IPv4 / CGNAT 的 HTTPS；证书 SHA-256 精确指纹校验 |

`invitation` 和 `fingerprint` 是 64 位小写十六进制文本；客户端校验端口为 1–65535。局域网不降级为 HTTP，不接受公网域名或任意自签名证书。内嵌网络代理不可失败后静默直连。Auth Key 不写入源码、日志或普通设置。

## 配对与访问

- `POST /v1/pair`：提交一次性 `invitation`、设备 `name`、随机设备令牌的 SHA-256 `tokenHash`，完整 Web 使用 `scope: web:access`。
- 返回 `id, code, expiresAt`；手机用自己的原始令牌作为 Bearer 轮询 `GET /v1/pair/:id`，读取 `id, approved, scope`。
- 初次配对必须由电脑明确批准。撤销后旧令牌不可读取状态、Web 或继续订阅。
- `GET /v1/status` 的当前响应为 `product: WeQ Remote, protocol: 1, scope: status:read, online: true`。这里的 `status:read` 是状态响应类别，不能据此推断设备拥有完整 Web 权限。
- Web 使用 `weq_remote` HttpOnly Cookie 或 Bearer 凭据；HTTP 与 `/trpc-ws` 由电脑端鉴权。手机壳不复制业务 API 定义或依赖桌面私有模块。
- iOS Keychain 服务名、Android Keystore 及 Bundle ID 不因拆仓库而改变；项目路径不属于设备授权标识。

## 版本与测试

手机 App 和电脑 WeQ 使用各自语义化版本，不要求版本号相同。当前继续兼容邀请 v1/v2/v3、状态协议 1 和完整 Web 授权；不兼容变更必须显式增加协议版本，并先给用户可理解的升级错误，不静默接受未知版本。

跨仓库测试约定：电脑 checkout 提供 `scripts/remote-integration-server.ts`，`GET /test/contract` 返回：

```json
{"fixture":1,"protocol":1,"invitationVersions":[1,2,3]}
```

其他测试控制入口为 `/test/invitation`、`/test/network`、`/test/devices`、`POST /test/revoke`；仅存在于回环合成服务，不能作为产品鉴权后门。测试网页和真实电脑侧配对实现由桌面仓库维护，手机端通过进程 / HTTP 入口使用，不再越过仓库边界直接 import。

日常协议单测保持完全离线；跨仓库夹具验证使用本机回环，隔离 TS 网络使用专用控制面 / DERP，不注册公共网络。构建通过不等于已完成真机、蜂窝切网或长期性能验收。
