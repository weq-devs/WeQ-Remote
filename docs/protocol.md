# WeQ Remote 协议

电脑端实现位于 [WeQ 的 Remote 模块](https://github.com/weq-devs/WeQ/tree/dev/apps/desktop/src/main/remote)，手机端见 [iOS 协议客户端](../apps/ios/Sources/RemoteProtocol.swift)、[Android 网络模块](../apps/android/network)及[共用本机网关](../apps/android/network/webgateway)。两端独立发布，当前状态协议为 1。不兼容变更须显式提升协议版本并提示升级。

## 邀请版本

邀请使用 `weq-remote://pair`，主 URL 无用户名、密码、端口、路径或 fragment。只有 v4 可重复传 `endpoint`，各地址必须不同。客户端拒绝未知与重复的其他字段。

| `v` | 字段 | 入口 |
| --- | --- | --- |
| 1 | `v, endpoint, invitation` | CGNAT 网段的 HTTP，经内嵌 Tailscale |
| 2 | v1 加 `authKey, expiresAt` | 同 v1，附一次性入网 Key |
| 3 | `v, endpoint, invitation, fingerprint` | 私网 IPv4 或 CGNAT 网段的 HTTPS，经系统路由 |
| 4 | `v, endpoint × 1–8, invitation, fingerprint`，可同时附 `authKey, expiresAt` | 可混合 v1 与 v3 的入口，附 Key 时必须包含内嵌入口 |

`invitation`、`fingerprint` 为 64 个小写十六进制字符，端口为 1–65535。`expiresAt` 为毫秒时间戳。HTTPS 精确校验证书 SHA-256 指纹。内嵌 HTTP 仅允许 `100.64.0.0/10`，代理不可退回直连。手机保留节点身份但不保存入网 Key。0.1.0 客户端仅支持 v1–v3。

## 配对、选路与访问

1. v4 首次配对先用 `GET /v1/hello` 核对 `product: WeQ Remote, protocol: 1`，找到可达入口后只提交一次 `POST /v1/pair`。网络结果不确定时也不跨入口重发。
2. 配对请求提交 `invitation`、设备 `name`、随机令牌的 SHA-256 `tokenHash` 和所需权限（完整 Web 使用 `scope: web:access`）。响应为 `id, code, expiresAt`。
3. 手机以原始令牌作为 Bearer 查询 `GET /v1/pair/:id`，读取 `id, approved, scope`，由电脑明确批准。iOS 单次轮询超时 3 秒，临时失败可在有效期内用原申请和令牌继续轮询。v4 换入口时仍用 hello 探测。授权拒绝、协议不兼容、过期或取消会结束配对。

v4 保存全部入口及公共指纹。候选按 150 毫秒错峰启动。首个成功结果胜出并取消其余探测。内嵌 HTTP 由同一 worker 顺序探测，按需入网，HTTPS 直连无需等入网。选路沿用正式请求预算。401、协议不兼容、证书失败或主动取消终止当前选择。恢复已授权连接时直接复用选路取得的鉴权状态。为已保存电脑重新扫码时，复用令牌验证新地址与指纹，成功后才替换。含新 Key 时先完成入网。旧连接资料在失败或停止时保留。

`GET /v1/status` 返回 `product: WeQ Remote, protocol: 1, scope: status:read, online: true`。`status:read` 仅表示响应类别。可选字段如下。

| 字段 | 含义 |
| --- | --- |
| `webRelease` | 正式 Remote HTML 在 `Accept-Encoding: identity` 下的小写 SHA-256，旧电脑和开发热更新省略 |
| `webAccountEntry: true` | 电脑支持轻量账号入口 `/_weq/connect` |
| `themeAccent` | 电脑主题色 `#rrggbb`。空字符串表示电脑使用默认色 |

配对及状态等原生请求可带 `X-WeQ-Device`，即 UTF-8 JSON 的标准 Base64（含 padding）。头值最多 2048 字符，字段为 `platform`（`ios` 或 `android`）和非空字符串 `model`、`osVersion`、`appVersion`、`appBuild`（每项最多 128 字符）。iOS 上报 uname，Android 上报厂商和型号。新电脑批准时保存，后续随授权请求更新。旧电脑忽略，缺失或无效资料不影响鉴权。电脑以最近 45 秒有授权请求显示「近期活跃」，网络类别按实际转发来源判断。

Web 使用 `weq_remote` HttpOnly Cookie 或 Bearer，HTTP 与 `/trpc-ws` 均由电脑鉴权。电脑撤销后旧凭据失效，手机收到 401 后按撤销流程退出并清理凭据及缓存。旧应用标识的安装需重新配对，见[迁移记录](../MIGRATION.md)。

## 网页与手机壳的本地接口

### 菜单、导航与偏好

| 接口 | 行为 |
| --- | --- |
| `window.weqRemoteShell.openMenu()` | 打开原生连接菜单。iOS 在主文档开始时注入。Android 在可见提交时注入并发送 `weq-remote-shell-ready`，加载完成时补注入。原生确认当前 WebView、导航轮次与网页按钮可操作后才交接。重载或渲染失效时恢复入口。 |
| `window.weqRemoteLinks.open(absoluteURL)` | 将当前电脑主文档的外链交给系统，覆盖异步跨源 `window.open`。空白窗口、同源链接、Blob 和鉴权下载走各自的原有路径。 |
| `window.weqMobileNavigation.back(): boolean` | Android 系统返回调用。已处理或正在处理返回为 true，顶层为 false，由系统处理。iOS 使用网页左缘手势。 |
| `window.weqRemoteNetworkCost` | 主文档初始化可读 `{state,constrained,metered,source}`，其中 `state` 为 `restricted`、`unrestricted` 或 `unknown`。Android 另有同步 JSON 入口 `weqRemoteLinks.networkCost()`。切网、Data Saver 变化或前台恢复时发送 `weq-remote-network-cost`。 |
| 省流量运行参数 | 网页通过 Android `networkPreference(mode)` 或 iOS `weqShell.postMessage({dataSaverMode:mode})` 设置本次连接的 `auto`、`always` 或 `never`。网页可将实际生效结果映射为后两者。缺省为 `auto`。原生用于更新取样决策。 |
| 主题色 | 默认按状态响应同步电脑主题色。字段缺失、无效或显式断开时，原生采用手机设置。关闭同步后，当前网页通过 iOS `window.weqRemoteThemeAccent` 或 Android `weqRemoteLinks.themeAccent()` 取得手机颜色，空串表示跟随电脑。开关或选色变更触发 `weq-remote-theme-accent`，只影响本端。 |
| `window.weqRemoteWindowLayout` | iOS 可选快照 `{width,height,topLeft:{width,height},topRight:{width,height}}`。几何变化发送 `weq-remote-window-layout`。iPadOS 26 起取物理左右的窗口角部占位（可能含圆角）。有占位时首屏显示前同步并等待两帧，网页只避让相交操作区。 |

原生连接菜单提供详情、立即检查、重新连接、断开和启动时自动连接。断开保留授权并暂停本次自动恢复。首页删除仅移除手机保存的电脑，电脑侧授权单独撤销。软件更新从 GitHub 发布目录按本机测试版偏好筛选版本，通过加速源读取对应标签的 `SHA256SUMS`，核对版本及平台后给出下载和备用源。省流量时跳过取样测速，测速失败按已验证的清单延迟排序。系统浏览器承接下载，安装及完整包校验由用户操作。

### 连接检测

- 前台每 15 秒复用 `GET /v1/status`。首轮总预算 5 秒，第二轮 10 秒，之后每轮增加 5 秒，成功后重置。入网与候选入口共用预算，失败重试至少间隔 500 毫秒。第二轮开始后 5 秒提示。无网络或网页失败持续 10 秒、前台 30 秒无成功验证也独立触发。提示与探测超时保留网页和代理。
- [共用观察脚本](../resources/web-connection-health.js)在 iOS 文档开始、Android 文档提交后注入，合并同源 fetch 网络拒绝和 WebSocket 错误／异常关闭。主动取消、正常关闭及外链失败排除。页面也可通过 `weqRemoteShell.connectionFailed?()` 补报既有失败。后台停止监听与计时，旧轮次结果丢弃。鉴权成功才判定恢复。
- `window.weqRemoteConnection` 保存 `{state,recovery?}`，`state` 为 `connected`、`network` 或 `connection`，`recovery` 计已提醒后恢复的次数。网页先读快照，再监听 `weq-remote-connection`，同一条 WeQ 横幅原地更新。未注入时使用网页自身的提示。[双端时间线用例](../tests/connection-health-vectors.json)覆盖检测规则。

### QQ 图片

- iOS 调用 `webkit.messageHandlers.weqQqImage.postMessage(url)`。Android 调用 `weqRemoteLinks.loadQqImage(id,url)` 并监听 `weq-remote-qq-image` 的 `{id,image}`。返回 `{type,base64}` 或回退电脑路径。只接收当前连接网页的受支持 HTTPS 图片，最多并行四张、单张至多 2 MiB，不跟随重定向或转发网页凭据。图片经手机系统网络，电脑网页和 WebSocket 仍走当前连接。
- 二进制能力标记为 iOS `window.weqRemoteBinaryImages === true` 或 Android `weqRemoteLinks.supportsBinaryImages()`。iOS 传 `{id,url}`，Android 调用 `loadQqImageBinary(id,url)`，成功返回 `{path}`。当前环回来源一次性 GET `/_weq-remote-local/image/<id>`，ID 为 32 个小写十六进制字符。最多暂存及交付四张，5 秒未读或关闭连接时释放。旧页面与旧壳继续支持 Base64。
- 装扮能力标记为 iOS `window.weqRemoteDressImages === true` 或 Android `weqRemoteLinks.supportsDressImages()`。仅允许 `tianquan.gtimg.cn` 的 `card/item`、`faceAddon/item` 图片，排除默认款、带参数地址、视频和资源包。能力缺失时由电脑提供对应资源。

### HTTP 页面设备采集

iOS 在当前 HTTP 主文档提供 `window.weqRemoteMedia`，HTTPS 继续用 `getUserMedia`。

- `start({id,audio?:true,video?:{width,height,fps,facingMode?}})` 开始，`stop(id)` 结束。`id` 为最多 64 个 ASCII 字母、数字或连字符。`facingMode` 为 `user` 或 `environment`。最多四项订阅，视频至多 640×480、15 fps。音频和同配置视频可复用采集源，冲突配置报错。
- `weq-remote-media` 事件以 `detail.id` 对应请求，`type` 为 `ready`、`audio`、`video`、`error` 或 `ended`。音频为 `{sampleRate:16000,channels:1,pcmBase64}`，每包 20 ms 小端 Int16 PCM。视频为 `{width,height,rgbaBase64,timestampMs}`，逐行紧凑 RGBA8888。错误携带 `message`。
- 最多等待一帧视频。音频交付过慢时结束对应采集。权限变化、重载、退后台、系统中断、断开及销毁会结束相关订阅。需手机 App 与电脑网页配套更新。

## 手机本机 Web 启动

两端为已配对授权提供带本机 Cookie 的固定环回来源。切换同一授权的连接路径时保留 origin，Android 持久保存端口映射，端口占用时提示重试。重连生成新的本机 Cookie 秘密，继续校验 Host／Origin／Cookie。

- **在线启动。** 首页「连接」与菜单「重新连接」走同一流程。状态带 `webAccountEntry: true` 时先打开 `/_weq/connect`，由电脑确认本机记住的账号或展示账号选择，再加载完整网页。旧电脑及旧手机壳从 `/` 启动。鉴权获得的 `webRelease` 若匹配已发布的本机构建，则直接复用。摘要不同或缺失时使用电脑当前网页。
- **缓存直开。** 首页根据本机已发布 HTML 提供入口，仅启动环回代理，未附加电脑路线，也不会自动重连。离线工作区使用已保存的账号、数据源和启动设置。后台用 `startup.snapshot` 核对账号与数据源，确认前业务 RPC 等待连接。核验失败保留已有数据。撤销、主动退出账号、启用隐私模式或应用锁会结束对应缓存启动资格。无完整网页或无缓存工作区时沿用在线启动。
- **准备离线包。** 以 `webRelease` 核对 HTML 摘要，通过 `weq-offline-code` 准备按需模块及打包静态资源。旧电脑和开发版兼容 `weq-offline-bundle` 或 `weq-startup-resources`。首次无完整包且 `waitForWorkspace: true` 时，进入账号后通过本机查询参数 `workspace=1` 启动准备。相同构建无需重新取 HTML 或分包。旧电脑可用 ETag `weq-release-<HTML SHA-256>` 检查。资源齐备后原子发布候选，失败保留已发布包。
- **资源复用。** 同一授权和选路下，前台与后台共用同编码、可缓存的哈希分包，WebView 流式读取，完整响应才可发布。打包开发版的 private immutable 分包仅在当前选路的内存中共享传输。Android 仅持久缓存公开、immutable 且带内容哈希的 JS/CSS，后台写盘，磁盘命中校验后复用内存副本。忘记电脑或撤销时取消待写缓存并清理文件。Android HTTPS 可协商 HTTP/2，兼容 HTTP/1.1。
- **版本提醒。** 本机 `/_weq-remote-local/release?notice=1` 返回备好的候选。省略该参数时返回当前使用版本。`since=<已知版本>` 在版本相同时最多等待 15 秒，页面关闭时取消。候选由用户重载启用。兼容的 Vite 热更新在当前页面生效，需要整页重载时提示。

### 网页就绪与首屏恢复

`window.weqRemoteStartup` 保存 `{state,message?}`，变化发送 `weq-remote-startup`。手机补读快照而无需轮询。

| 状态 | 手机行为 |
| --- | --- |
| `loading` | 留在连接页，显示实际阶段。45 秒未完成则提示超时 |
| `ready` | 必要配置、恢复、账号探测和界面绘制完成后显示网页。业务列表在界面内异步加载 |
| `action-required` | 展示需要操作的恢复或诊断页面 |
| `error` | 返回连接页提示重试。仅 HTML 加载完成不足以判定就绪 |

新版电脑通过 `window.weqRemoteStartupRecovery = true` 声明首屏资源恢复。清单内脚本／样式、动态预载失败或资源／界面模块连续 15 秒无进展时，最多等 10 秒用 `cache: reload` 重取失败或未完成资源，然后仅重载尚未就绪的页面。URL 参数 `__weqStartupRetry=1` 限制为一次，重取或重载再次失败时发布 `error`。`ready`、`action-required` 后移除参数。网页进入终态或离开即停止观察，账号和恢复检查不计入资源停滞，渲染异常直接上报。Android 资源错误回调按当前导航核对标记，旧网页使用原生失败提示。iOS 沿用导航与启动桥。

## 首屏资源进度

- **清单。** 电脑识别 `WeQRemote` User-Agent，在 HTML 内嵌 `meta[name="weq-startup-resources"]`，JSON 为 `{version:1,resources:[{path:"/assets/name-hash.js",size:1234}]}`。正式构建按同源静态 JS/CSS 去重，大小按压缩协商选择。电脑优先复用匹配 HTML 的 `weq-startup.json` 原始／gzip 数据，缺失或无效时现场计算。工作区专用代码另列入离线清单。打包热更新用首批资源原始字节。
- **完成回执。** 电脑在资源标签之前记录 load／error，保存 `window.weqRemoteResourceLoads` 并发送 `weq-remote-resource-load`。手机用回执与 Resource Timing 补读早到资源，按已完成资源的清单权重显示百分比和项数，缓存命中计入权重，失败与重复回执不增加完成量。更新在 100 毫秒内合并。圆环到 100% 后保留至页面就绪或进入其他终态。阶段标题沿用网页报告，新导航清零。
- **来源字段。** 本地资源桥提供 `{completed,total,loadedBytes,totalBytes}` 及可选的 `{downloadedBytes,cachedBytes,unknownBytes}`。下载量只累计确认来自网络且已完成的资源响应 `encodedBodySize`。同一 timing 不重复累计。缓存和未知字节是内部权重，旧回执无来源时只显示进度。全缓存提示要求 `completed=total`、`downloadedBytes=0`、`cachedBytes=totalBytes`、`unknownBytes=0`，此时折叠明细。
- **来源判定。** 结合资源的 `deliveryType`、传输／响应体字段与 304 校验结果。Android 环回响应通过 `Server-Timing: weq-remote-source;desc="cache"` 或 `desc="network"` 标记上游来源。标签不进入原生缓存副本，浏览器缓存命中优先。WebKit 空指标须同时满足真实 load 成功、无 Service Worker、同源、`fetchStart=requestStart>0`、`responseStart=0`、`responseEnd>=fetchStart` 和三项尺寸全零，才计内存复用。跨源、重定向或缺少 timing 时不推断来源。
- **计量范围。** 下载字节覆盖已确认的代码资源响应体，部分 WebKit 还包含 HTTP/1.1 分块开销。HTML、API、媒体、HTTP 头和 TLS 不计。旧电脑缺少清单时用不定进度。逐模块热更新可通过 `window.weqRemoteDevelopmentResources` 保存 `{completed,downloadedBytes,cached,unknown}`，其中 `cached` 与 `unknown` 为项数。iOS 用 `weqDevelopmentResources.postMessage`，Android 用 `weqRemoteLinks.developmentResources`（JSON 字符串），旧壳沿用字符串提示。

用 [资源来源夹具](../scripts/check-web-resource-timing.mjs)从回环服务器独立计数，复核冷加载、无变化、小文件变化和分块响应。运行 `node scripts/check-web-resource-timing.mjs`，复用已安装的 Playwright，可用 `WEQ_PLAYWRIGHT_IMPORT`、`WEQ_CHROMIUM_EXECUTABLE`、`WEQ_WEBKIT_EXECUTABLE` 指定模块或浏览器。

## 本机业务缓存

两端共用环回接口 `/_weq-remote-local/cache`，数据按电脑授权存放。默认 256 MiB，目录、历史、媒体和常用页面共用预算，按最近使用时间淘汰。代码缓存、草稿、设置与设备令牌独立保存。

| 请求 | 行为 |
| --- | --- |
| `GET` | 返回用量、上限和写入代次 |
| `PUT ?limit=<bytes>` | 设上限，接受 16–4096 MiB 的整数档位 |
| `DELETE` | 清理业务记录并递增代次 |

记录写入携带 `X-WeQ-Cache-Generation`，清理会使旧代次写入失效。电脑对已确认账号来源的媒体返回 `X-WeQ-Cache-Scope`。网关可离线读取完整视频的字节范围，已有片段可按同一范围重放。普通读操作缓存成功结果，变更仍发往电脑。

原生菜单可在本机网页会话中管理缓存，成功后调用网页的 `weqLocalCacheChanged(cleared)` 刷新预算或清掉旧业务镜像。清理后仍会重载旧网页。旧手机壳沿用网页弹窗和原有缓存接口。

iOS 主框架的 `weqBusinessCache` 为既有目录、近期聊天尾窗和小头像提供同一授权下的有界镜像，忘记电脑或撤销时清理。`weqRemoteBusinessRecords === 1` 表示支持目录与近期消息的增量读写。

- `putRecords` 带 `scope,kind,savedAt,revision,keys` 及变动的 `{key,payload}`。键有序，payload 是单条查询的 SuperJSON 文本。携带 `base` 时须匹配当前修订，收到 `needsFull` 可省略 `base` 重送完整记录。结果为 `stored`、`unchanged` 或 `unavailable`。
- 记录先落盘，再原子替换清单。同分区的旧格式和新格式共用预算。`getRecords` 按 `newerThan` 返回更新记录或旧快照。旧壳沿用 `get`／`put`。小头像继续走原桥。缺少能力或数据时按现有途径获取。

## 联调夹具

先按锁文件安装 WeQ 电脑仓库依赖，再从手机仓库根目录启动夹具。

```sh
export WEQ_DESKTOP_REPO=/path/to/WeQ
python3 scripts/desktop_fixture.py --desktop-repo "$WEQ_DESKTOP_REPO"
```

[手机端入口](../scripts/desktop_fixture.py)启动 WeQ 的 `scripts/remote-integration-server.ts`，默认在 `127.0.0.1:45198` 使用合成数据及自动批准。LAN 加 `--lan`。隔离 Tailscale 使用专用控制面／DERP，详见 [iOS](../apps/ios/README.md#模拟器联调)与 [Android](../apps/android/README.md#专用模拟器与联调)。测试结束关闭本轮服务，撤销测试只在专用测试环境执行。

`GET /test/contract` 返回 `{"fixture":1,"protocol":1,"invitationVersions":[1,2,3,4]}`。其他夹具入口为 `/test/invitation`、`/test/network`、`/test/devices` 及 `POST /test/revoke`。下列命令从电脑仓库验证独立客户端的夹具契约与配对往返。

```sh
cd "$WEQ_DESKTOP_REPO"
WEQ_REMOTE_CLIENT_REPO=/path/to/WeQ-Remote node --test scripts/remote-integration-server.test.mjs
```
