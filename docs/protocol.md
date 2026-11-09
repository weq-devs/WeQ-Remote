# 电脑与手机的协议边界

本文件描述当前两边已经实现的契约，不是新增一套协议。权威实现分别位于 WeQ 的 `apps/desktop/src/main/remote` 与本仓库两平台的协议客户端；任一侧变更均需运行另一侧能推翻兼容假设的反例测试。

## 邀请版本

共同格式为 `weq-remote://pair`，不接受未知字段，不携带 URL 用户名、密码、路径或 fragment。只有 v4 的 `endpoint` 可以重复；其他字段以及旧版本全部字段必须唯一。

| `v` | 字段 | 传输 |
| --- | --- | --- |
| 1 | `v, endpoint, invitation` | 内嵌 TS 的 `http://100.64.0.0/10:<port>` |
| 2 | v1 字段加 `authKey, expiresAt` | 内嵌 TS；Auth Key 仅用于本次入网，过期字段为毫秒时间戳 |
| 3 | `v, endpoint, invitation, fingerprint` | 私有 IPv4 / CGNAT 的 HTTPS；证书 SHA-256 精确指纹校验 |
| 4 | `v, endpoint × 1–8, invitation, fingerprint`，可选同时带 `authKey, expiresAt` | 多入口：局域网 HTTPS、WeQ 专用节点 HTTP（内嵌 TS）/ HTTPS（系统路由）；错峰竞速探测，不接受重复地址 |

`invitation` 和 `fingerprint` 是 64 位小写十六进制文本；客户端校验端口为 1–65535。局域网不降级为 HTTP，不接受公网域名或任意自签名证书。内嵌网络代理不可失败后静默直连。Auth Key 不写入源码、日志或普通设置。

## 配对与访问

- v4 先调用 `GET /v1/hello`，验证 `product: WeQ Remote, protocol: 1`，不消费邀请、不读取账号或授权数据。确认路径可达后只提交一次配对 POST；网络结果不确定时不在其他路径重发 POST。
- v4 保存全部地址与公共指纹，不保存 Auth Key。初连、恢复连接或只读请求连接失败时，以 150 毫秒间隔启动候选地址探测，首个成功结果胜出并取消其余探测，不逐个累加超时。已配对设备恢复连接时，探测本身就是一次鉴权状态读取，成功结果直接作为本次连接的校验，不再追加一次状态请求；尚未批准的设备不能读取状态，只用 hello 确认路径可达。探测沿用正式请求的超时预算，不为选路另设更短的硬超时。内嵌 HTTP 地址由同一个 worker 依次探测，节点入网按需启动，不作为 HTTPS 直连的前置条件。入网未完成时，不用新节点身份替换原来保存的身份。401、协议不兼容、取消与证书校验失败仍会结束当前选择，不因换路而忽略；竞速已经成功后取消的其他探测不影响胜出结果。HTTPS 始终使用公共指纹，HTTP 地址仅通过内嵌 TS。
- `POST /v1/pair`：提交一次性 `invitation`、设备 `name`、随机设备令牌的 SHA-256 `tokenHash`，完整 Web 使用 `scope: web:access`。
- 返回 `id, code, expiresAt`；手机用自己的原始令牌作为 Bearer 轮询 `GET /v1/pair/:id`，读取 `id, approved, scope`。
- iOS 批准轮询的单次请求超时为 3 秒，临时连接失败保留本次请求与令牌，在有效期内重试。v4 可重新探测入口后继续读取同一个请求，不重新提交配对 POST；未批准时以 hello 而非 status 探测。授权拒绝、响应不兼容、用户取消和请求过期仍结束配对。
- 初次配对必须由电脑明确批准。撤销后旧令牌不可读取状态、Web 或继续订阅。
- `GET /v1/status` 的当前响应为 `product: WeQ Remote, protocol: 1, scope: status:read, online: true`。这里的 `status:read` 是状态响应类别，不能据此推断设备拥有完整 Web 权限。
- Web 使用 `weq_remote` HttpOnly Cookie 或 Bearer 凭据；HTTP 与 `/trpc-ws` 由电脑端鉴权。手机壳不复制业务 API 定义或依赖桌面私有模块。
- 拆仓库本身不改变设备授权；后续隐私清理将应用标识与 iOS Keychain 服务名改为项目命名空间 `io.github.weqdevs.remote`。新身份不能读取旧应用凭据，需重新配对；既有安装与电脑授权未被改动。项目路径不属于设备授权标识。

## 网页与手机壳的本地接口

- 壳向当前电脑网页注入 `window.weqRemoteShell.openMenu()`，网页仅在接口存在时显示连接菜单。iOS 在主文档开始加载时注入；Android 在页面加载完成时注入，并发送本地事件 `weq-remote-shell-ready`，不握手、不轮询、不新增网络请求。
- 菜单由原生呈现，包含重新加载、断开和取消。重载复用当前 WebView 及凭据；断开清理当前连接但保留已保存电脑，并暂停本次运行的自动恢复；删除仅在首页确认后执行，不撤销电脑上的设备授权。
- 新版移动网页提供 `window.weqMobileNavigation.back(): boolean`。Android 系统返回调用该接口，已处理或正在处理返回时返回 true；顶层返回 false，由系统处理，不自动断开。iOS 使用网页左缘手势，不同时开启 WKWebView 返回手势。
- 两端修改不改变邀请、配对、状态或网络协议，也不要求电脑和手机版本号一致。

## 版本与测试

手机 App 和电脑 WeQ 使用各自语义化版本，不要求版本号相同。当前开发版新增 v4，并继续兼容邀请 v1/v2/v3、状态协议 1 和完整 Web 授权；已发布的 0.1.0 不会因电脑更新而自动获得 v4 解析能力，需要更新手机 App。不兼容变更必须显式增加协议版本，并先给用户可理解的升级错误，不静默接受未知版本。

跨仓库测试约定：电脑 checkout 提供 `scripts/remote-integration-server.ts`，`GET /test/contract` 返回：

```json
{"fixture":1,"protocol":1,"invitationVersions":[1,2,3,4]}
```

其他测试控制入口为 `/test/invitation`、`/test/network`、`/test/devices`、`POST /test/revoke`；仅存在于回环合成服务，不能作为产品鉴权后门。测试网页和真实电脑侧配对实现由桌面仓库维护，手机端通过进程 / HTTP 入口使用，不再越过仓库边界直接 import。

日常协议单测保持完全离线；跨仓库夹具验证使用本机回环，隔离 TS 网络使用专用控制面 / DERP，不注册公共网络。构建通过不等于已完成真机、蜂窝切网或长期性能验收。
