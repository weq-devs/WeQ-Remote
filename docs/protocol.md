# 电脑与手机的协议边界

本文件描述当前两边已经实现的契约，不是新增一套协议。权威实现分别位于 WeQ 的 `apps/desktop/src/main/remote` 与本仓库两平台的协议客户端；任一侧变更均需运行另一侧能推翻兼容假设的反例测试。

## 系统网络费用桥

手机壳在主文档初始化时提供 `window.weqRemoteNetworkCost = {state:'restricted'|'unrestricted'|'unknown', constrained:boolean, metered:boolean, source:string}`，后续变化发送 `weq-remote-network-cost` 事件。Android 另提供同步的 `weqRemoteLinks.networkCost()` JSON 读取入口，避免文档提交后注入晚于业务初始化；iOS 使用 document-start 用户脚本。切网、Data Saver 变化及返回前台重新读取，不改变连接健康判定或新增探测心跳。

网页通过 Android 的 `networkPreference(mode)` 或 iOS `weqShell.postMessage({dataSaverMode:mode})` 传回当前连接的省流量运行参数，手机不提供本地覆盖。桥继续接受 `auto|always|never`；新版网页将宿主与本端合并后的实际生效结果映射为 `always|never`，使既有手机壳的更新检查也遵循默认关闭的「使用流量时自动启用」共享选项及临时覆盖，不必新增桥字段。该参数用于原生更新检查是否取样测速；没有网页提供参数时仍默认为 auto，原生默认行为不变。旧壳缺少桥时网页保留 unknown 和手动模式，不假装识别系统状态；邀请与授权协议版本不变。

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
- 已保存电脑时，重新扫码只更新连接资料：复用原设备令牌调用 `GET /v1/status` 验证新入口，成功后保存地址与指纹，不调用配对 POST、不消费二维码中的一次性邀请，也不生成新设备令牌。包含新 Auth Key 的更新先完成入网，保留节点身份但不保存 Key；失败或停止时不替换原地址与设备令牌。支持整套正式网页缓存的电脑在状态响应附加可选的 `webRelease`，为 `Accept-Encoding: identity` 所得 Remote HTML 的小写 SHA-256。开发热更新和旧电脑省略此字段。
- v4 保存全部地址与公共指纹，不保存 Auth Key。初连、恢复连接或只读请求连接失败时，以 150 毫秒间隔启动候选地址探测，首个成功结果胜出并取消其余探测，不逐个累加超时。已配对设备恢复连接时，探测本身就是一次鉴权状态读取，成功结果直接作为本次连接的校验，不再追加一次状态请求；尚未批准的设备不能读取状态，只用 hello 确认路径可达。探测沿用正式请求的超时预算，不为选路另设更短的硬超时。内嵌 HTTP 地址由同一个 worker 依次探测，节点入网按需启动，不作为 HTTPS 直连的前置条件。入网未完成时，不用新节点身份替换原来保存的身份。401、协议不兼容、取消与证书校验失败仍会结束当前选择，不因换路而忽略；竞速已经成功后取消的其他探测不影响胜出结果。HTTPS 始终使用公共指纹，HTTP 地址仅通过内嵌 TS。
- `POST /v1/pair`：提交一次性 `invitation`、设备 `name`、随机设备令牌的 SHA-256 `tokenHash`，完整 Web 使用 `scope: web:access`。
- 返回 `id, code, expiresAt`；手机用自己的原始令牌作为 Bearer 轮询 `GET /v1/pair/:id`，读取 `id, approved, scope`。
- iOS 批准轮询的单次请求超时为 3 秒，临时连接失败保留本次请求与令牌，在有效期内重试。v4 可重新探测入口后继续读取同一个请求，不重新提交配对 POST；未批准时以 hello 而非 status 探测。授权拒绝、响应不兼容、用户取消和请求过期仍结束配对。
- 初次配对必须由电脑明确批准。撤销后旧令牌不可读取状态、Web 或继续订阅。
- `GET /v1/status` 的当前响应为 `product: WeQ Remote, protocol: 1, scope: status:read, online: true`。这里的 `status:read` 是状态响应类别，不能据此推断设备拥有完整 Web 权限。
- 开发源码的 iOS／Android 在现有原生协议请求附带可选 `X-WeQ-Device`：UTF-8 JSON 的标准 Base64（含 padding），字段为 `platform: ios|android`、`model`、`osVersion`、`appVersion`、`appBuild`，后四项均为非空字符串，每项最多 128 字符，请求头最多 2048 字符。iOS 的 model 为 uname 硬件标识，Android 为厂商与系统型号。配对 JSON 正文不增加字段，旧电脑直接忽略此头；新电脑在批准配对时保存资料，并在后续授权请求自动更新，不需重新配对。旧手机不带此头仍可访问，损坏资料不阻断鉴权、不清空已知资料。前台沿用每 15 秒的状态验证，不增加心跳；电脑以最近 45 秒授权访问显示「近期活跃」，并从网络助手转发链的实际来源识别最近 IP 与 LAN／Tailscale，不信任手机自报网络类型。活跃与来源资料合并保存，不逐个资源请求写盘。
- Web 使用 `weq_remote` HttpOnly Cookie 或 Bearer 凭据；HTTP 与 `/trpc-ws` 由电脑端鉴权。手机壳不复制业务 API 定义或依赖桌面私有模块。
- 拆仓库本身不改变设备授权；后续隐私清理将应用标识与 iOS Keychain 服务名改为项目命名空间 `io.github.weqdevs.remote`。新身份不能读取旧应用凭据，需重新配对；既有安装与电脑授权未被改动。项目路径不属于设备授权标识。

## 网页与手机壳的本地接口

- 新版手机壳按需提供 QQ 图片桥：iOS 使用 `webkit.messageHandlers.weqQqImage.postMessage(url)` 的回复；Android 使用 `weqRemoteLinks.loadQqImage(id, url)` 和 `weq-remote-qq-image` 事件，事件详情为 `{id,image}`。成功图片为 `{type,base64}`，失败走原电脑路径。只接收当前连接网页发来的指定 HTTPS 头像和聊天缩略图请求，最多并行四张、单张最多 2 MiB，不跟随重定向或转发 WebView 凭据。图片走手机系统网络，电脑网页和 WebSocket 仍经原连接。设置独立于普通浏览器和桌面，默认关闭；旧壳不提供该桥，不影响配对和聊天。
- 支持二进制交付的手机壳额外提供 iOS `window.weqRemoteBinaryImages === true` 或 Android `weqRemoteLinks.supportsBinaryImages()`。iOS 的图片桥接收 `{id,url}`，Android 用 `loadQqImageBinary(id,url)`；成功回复 `{path}`。网页从当前已认证的环回来源一次性 GET `/_weq-remote-local/image/<id>`，直接读图片原始字节。ID 为 32 位小写十六进制，环回只交付已经由手机验证并下载完成的图片。暂存和正在交付合计最多四张，未读取的图片 5 秒后清除，连接关闭时清除暂存。旧网页与旧手机壳仍可使用 Base64 回复。
- 支持公开装扮图的手机壳额外提供 iOS `window.weqRemoteDressImages === true` 或 Android `weqRemoteLinks.supportsDressImages()`。复用同一图片桥，仅允许 `tianquan.gtimg.cn` 的 `card/item` 和 `faceAddon/item` 图片，不取默认款、带参数地址、视频或资源包。旧壳无此能力标记时，网页继续使用电脑路径，不改变头像和聊天缩略图的行为。

- iOS 壳提供可选 `window.weqRemoteWindowLayout = {width,height,topLeft:{width,height},topRight:{width,height}}`，坐标为与全屏 WebView 对齐的容器点坐标；iPadOS 26 起取自公开 `GeometryProxy.containerCornerInsets`，按当前布局方向转换为物理左右，旧系统和全屏无角部占位时为零。角部也可能包含系统圆角，不把非零值当作某一种窗口模式。主文档开始时请求当前快照，几何变化后发送 `weq-remote-window-layout`；存在角部占位时，首屏准备好后再同步并等待两帧绘制才显示，无占位时不新增等待。网页根据布局视口换算、只调整相交操作区，普通安全区不重复累加。仅本地布局桥接，无新增网络请求、持久设置或版本协议要求；旧网页忽略该值，旧壳和 Android 不提供时维持原布局。

- 壳向当前电脑网页注入 `window.weqRemoteShell.openMenu()`，网页仅在接口存在时显示连接菜单。iOS 在主文档开始加载时注入；Android 在主文档可见提交时注入，并发送本地事件 `weq-remote-shell-ready`，加载完成时补注入。原生通过本地脚本确认顶栏菜单实际可点，并核对当前 WebView 和导航轮次，才将入口交给网页。仅收到 `ready` 或 `action-required` 不移除原生入口；重载、渲染进程失效、退出工作区且网页没有菜单时恢复入口。菜单仍打开时不因交接关闭，不增加网络请求。
- 两端提供 `window.weqRemoteLinks.open(absoluteURL)` 将外链交给手机系统，并包装主文档的跨源 `window.open`，让异步业务回调拿到链接后仍可打开，不依赖浏览器瞬时用户激活。iOS 本地消息核对当前 WebView、主框架及电脑来源，沿用 `RemoteWebPolicy.external` 的地址规则；空白窗口、同源链接、Blob 及原有鉴权下载不经外链桥，不把主聊天页改成外部站点。
- 网页通过 `window.weqRemoteStartup` 保存 `{state, message?}`，变化时发送本地事件 `weq-remote-startup`。`loading` 期间手机留在首页，并显示 `message` 对应的实际阶段；恢复检查、账号探测、必要配置及真实界面绘制完成后以 `ready` 放行。会话、好友、昵称、在线状态等业务数据在正式界面内异步加载，不属于启动等待条件。`error` 将错误交回首页重试；需要用户操作的恢复回执或组件诊断用 `action-required` 展示可操作页面。HTML 加载或查询结束不再视为界面已渲染；两端加载后补读当前状态，避免遗漏早到事件，不轮询、不额外请求。45 秒未完成则在首页报告超时；此能力需同时更新电脑网页与手机安装包，旧网页不会因 HTML 完成而被误判就绪。
- 新版电脑在入口模块前提供 `window.weqRemoteStartupRecovery = true`，负责首屏资源的一次自动重试：清单内脚本／样式失败、动态模块预载失败，或资源／界面模块连续 15 秒无进展时触发。优先以 `fetch` 的 `cache: reload` 重新取得已失败资源，无明确失败项时重取尚未完成项，最多 10 秒；成功后重载尚未就绪的页面，避免 WebKit 跨页面沿用失败预载。重取失败或重载后仍失败则发布 `error`，不继续循环。当前文档 URL 的 `__weqStartupRetry=1` 标记限制本轮次数，成功或 `action-required` 后移除，不改授权、账号或浏览器来源。`ready`、`action-required`、`error`、页面离开均结束观察；恢复／账号检查不算资源停滞，渲染异常直接上报，不自动重跑业务子树。Android 资源错误回调异步核对此标志，新页面负责重试及最终错误，旧页面维持原生提示；异步结果不跨网页轮次处理。iOS 使用原有导航和启动桥即可，Android 需更新安装包，不修改协议版本。
- 菜单由原生呈现，展示连接、系统、App 版本／构建、Tailscale 与最近成功验证信息，并提供立即检查、软件更新、检查测试版开关、重新加载和断开。首页「更多」复用同一详情入口；次要状态不铺在首页。重载复用当前 WebView 及凭据；断开清理当前连接但保留已保存电脑，并暂停本次运行的自动恢复；删除仅在首页确认后执行，不撤销电脑上的设备授权。
- 两端前台已有连接每 15 秒复用 `GET /v1/status` 验证，首轮总预算 5 秒，第二轮 10 秒，之后每轮增加 5 秒，验证成功后重置；失败后的重试至少间隔 500 毫秒。第二轮开始后 5 秒即显示提醒，不取消尚余的请求预算；该轮入网、错峰及所有备用入口共用总预算，不再串联多个完整超时。超时仅取消探测，不关闭现有网页或代理；成功后确需换入口时沿用原有重建流程。401 撤销仍走原清理流程。
- 提醒独立于请求：无可用网络或首次网页失败持续 10 秒，或者前台 30 秒没有成功验证，也会触发。系统网络变化合并检查，网络恢复本身不清除提醒。两端用单调时钟和一次性计时器，后台停止监听与计时，返回前台重新计算预算；旧前台轮次的异步结果不更新新轮次状态，已有提醒保留至鉴权状态验证成功。生产状态机由 `tests/connection-health-vectors.json` 同一份时间线逐步核对。
- 两端复用 `resources/web-connection-health.js` 的同源失败观察：iOS 在主文档开始时注入，Android 在文档提交后注入；fetch 网络拒绝（排除 AbortError）与 WebSocket error／非正常 close 经各自本地桥触发检查。注入前已建立的网页实时连接由共用 Web 的连接状态补报。脚本不改变请求、返回值或错误，不重放业务操作；外部来源失败不影响电脑连接状态。事件限流，忙碌时合并等待，不丢弃网络变化；断开或退后台后取消待执行检查。网页成功响应不代替原生鉴权状态验证，不修改电脑协议。
- 壳向当前电脑网页保存 `window.weqRemoteConnection = {state:'connected'|'network'|'connection',recovery?:number}` 并发送本地事件 `weq-remote-connection`；`recovery` 是本次连接实际从已提醒状态恢复的次数，用于新网页补读恢复回执。共用 Web 先补读状态再监听事件，通过现有 WeQ 横幅按稳定 key 原地更新断连／恢复提示，原生不再添加顶部条；相同状态不重复推送，恢复提示遵循成功通知时长。壳未提供状态时，普通 Web 仍使用自身实时连接提示。`weqRemoteShell.connectionFailed?()` 用于补报已经处于失败状态的实时连接，仅触发原生检查，不改变网络协议。
- 软件更新不经过电脑业务协议：手机读取本仓库 GitHub 公开发布目录，按本机「检查测试版」筛选已发布且含清单的版本，再通过加速源读取该标签的 `SHA256SUMS`，要求清单与选定版本、当前平台匹配。测试发布分类同时检查 GitHub `prerelease` 和版本名 Beta 标识；不降低到比当前更旧的版本。取样测速失败时按已验证的清单延迟排序，下载使用固定版本地址并提供备用源。安装包交由系统浏览器，不声称已执行完整包校验或自动安装。
- 新版移动网页提供 `window.weqMobileNavigation.back(): boolean`。Android 系统返回调用该接口，已处理或正在处理返回时返回 true；顶层返回 false，由系统处理，不自动断开。iOS 使用网页左缘手势，不同时开启 WKWebView 返回手势。
- 两端修改不改变邀请、配对、状态或网络协议，也不要求电脑和手机版本号一致。

### HTTP 页面设备采集

- iOS 只为 HTTP 连接页面在文档开始时注入 `window.weqRemoteMedia`；HTTPS 沿用网页的 `getUserMedia`。桥由当前主文档、当前电脑来源发起，不把设备采集改成电脑采集。
- `start({id,audio?:true,video?:{width,height,fps,facingMode?:'user'|'environment'}})` 开始订阅，`stop(id)` 结束。`id` 为最多 64 位的 ASCII 字母、数字和连字符；同时最多四项订阅，音频与相同配置的视频复用同一采集源。视频最多 640×480、15 fps；摄像头配置冲突时返回错误。
- 结果发送为本地 `weq-remote-media` 事件，`detail.id` 对应请求，`type` 为 `ready`、`audio`、`video`、`error` 或 `ended`。`audio` 带 `{sampleRate:16000,channels:1,pcmBase64}`，内容为每包 20 ms 的小端 Int16 PCM；`video` 带 `{width,height,rgbaBase64,timestampMs}`，内容为逐行紧凑 RGBA8888；`error` 带 `message`。
- 视频最多保留一帧等待网页处理；音频交付过慢时结束对应采集并报告错误，不无限积压。设备权限、页面重载、退后台、系统中断、断开和销毁按订阅收尾。桥只传设备媒体，不新增业务或网络协议；手机安装包与共用网页需要配套更新。

## 手机本机 Web 启动

- 两端为已配对授权提供带本机 Cookie 的固定环回来源。已缓存可用网页时，第一张 App 页面是缓存 Web，授权验证及选路同时进行，不显示整张原生连接页，网页顶栏最后一位的连接菜单就绪前保留同位置的原生入口。核验成功后原来源转发业务 HTTP／WebSocket，换路保留原来源、WebView 和 IndexedDB。明确撤销时按原连接流程退出并清理代码缓存。
- 有 `webRelease` 时按 `weq-offline-code` 准备整套正式网页资源，含按需模块和打包静态图；下载前核对 HTML 摘要。相同已缓存构建不查 HTML 或拉取分包。开发版和旧电脑继续用 `weq-offline-bundle` 或 `weq-startup-resources` 兼容。首次无完整离线包且清单给出 `waitForWorkspace: true` 时，网关等网页进入账号后通过本机 `workspace=1` 启动后台准备。复用已有的同名哈希资源，只在资源齐备后原子发布候选；失败继续使用上一套。
- 在同一授权和选路下，前台浏览和后台离线包共用可缓存的同编码哈希分包。WebView 边接收边读取，离线包取得完整且有效的正文后才发布。打包开发版的 private immutable 分包只在当前选路的内存中共享传输，完整离线包仍按原规则发布。
- 缺少正式构建摘要时，网关沿用 `If-None-Match: "weq-release-<HTML SHA-256>"` 检查，支持此约定的电脑在版本相同时返回 304。不额外增加鉴权心跳。
- 本机 `/_weq-remote-local/release?notice=1` 返回已备好的候选；未带 `notice=1` 只返回当前使用版本，旧网页不会因收到候选而自动重载。支持等待时 `since=<已知版本>` 最多挂起 15 秒；收起页面取消等待。冷启动使用已准备好的候选。点击原生连接菜单「重新加载」会立即通过当前鉴权路线向电脑重新验证网页，跳过后台检查间隔，取得完整分包后切换；网页版本相同时复用原有资源。电脑只提供在线网页时直接加载，保留已有离线副本。检查或资源准备失败时提示重试，保留已就绪的页面。同时发生的后台准备为手动重载让位。开发态兼容更新经 Vite 在当前文档内生效；断线恢复 HMR 连接、整页回退只提示，不代替用户确认。
- Web 启动只额外记住账号和数据源标识与启动页设置，目录、消息及头像沿用原业务缓存。后台使用 startup.snapshot 核对账号与数据源，失败时保留缩略图和完整正文的已有缓存。核对完成前业务 RPC 继续等待连接；撤销、主动退出账号、启用隐私模式或应用锁会结束相应的缓存启动资格。无完整网页或无已缓存工作区时沿用在线启动。

## 首屏资源进度

- 电脑识别 `WeQRemote` User-Agent，在 HTML 的 `meta[name="weq-startup-resources"]` 中附带 JSON `{version:1,resources:[{path:"/assets/name-hash.js",size:1234}]}`。正式构建按 HTML 入口的同源静态 JS/CSS 依赖去重，逐项给出本次压缩协商下的响应体大小。工作区专用代码单列于离线清单。
- 新版电脑在构建时生成 `weq-startup.json`，保存首屏依赖及原始／gzip 大小；匹配当前 HTML 后复用，不在连接时重复压缩计算。缺少、过期或无效清单时兼容原有现场计算路径。同一份构建在电脑内存复用，HTML 更新后重新读取；手机不为清单增加请求，普通浏览器不附加清单。
- 恢复检查和账号选择无需加载聊天工作区专用分包。进入已打开账号后，工作区加载与账号初始化并行。实际账号和恢复检查仍由现有接口完成。
- 电脑在资源标签之前记录真实 `load/error`，通过 `window.weqRemoteResourceLoads` 保存每个资源的完成／失败结果，并发送 `weq-remote-resource-load`；手机结合该回执与 Resource Timing 补读早到资源，避免 WebKit 内存缓存 timing 尺寸为零或 Android 桥接稍晚造成漏记。
- 手机圆环继续采用已完成资源的清单字节数／清单总字节数，显示「资源加载」百分比和资源项数，不显示清单体积。缓存命中计入加载权重；每个资源完成后累计，100 毫秒内合并更新。失败不计完成，重复回执不重复累计。资源到 100% 后圆环保留到页面就绪或进入其他终态，阶段标题按网页实际状态更新。
- 打包热更新页通过同一个清单提供首批资源百分比。每次开发构建把入口及静态 JS/CSS 依赖的原始字节数写入同一份 HTML，后续动态分包继续按需加载。圆环复用现有资源桥，确认下载量仍取实际编码字节。首批资源加载完成后继续显示安装包现有的初始化阶段。
- 逐模块热更新及缺少清单时，支持开发进度桥的手机壳通过 `{completed, downloadedBytes, cached, unknown}` 显示已完成项数，其中 `cached` 和 `unknown` 也是项数。iOS 使用 `weqDevelopmentResources.postMessage`，Android 使用 `weqRemoteLinks.developmentResources`（JSON 字符串）；主文档保留 `window.weqRemoteDevelopmentResources` 供提交时补读。旧手机壳继续接收原有字符串提示。
- 只有 `completed=total`、`downloadedBytes=0`、`cachedBytes=totalBytes`、`unknownBytes=0` 同时满足才认定全缓存，界面折叠为「已复用网页缓存」，不展示下载字节／百分比／项数明细；不根据 Web 版本未变化或历史缓存记录提前假定全缓存。
- 本地资源桥在原 `{completed,total,loadedBytes,totalBytes}` 外支持可选的 `{downloadedBytes,cachedBytes,unknownBytes}`。`downloadedBytes` 累计已确认网络来源的已完成资源响应的 `encodedBodySize`，同一 timing 对象的补读不重复累计；大于零时显示为「已下载」。`cachedBytes`、`unknownBytes` 是已加载资源中缓存复用或未能分类部分的内部权重，不用于展示体积，也不要求与实际下载字节数相加等于加载量。旧回执没有来源字段时继续显示加载进度，不显示下载量。
- 浏览器来源以同源 Resource Timing 的 `deliveryType`、传输／响应体字段及 304 校验结果核对。Android 的回环代理读取不等于上游下载：原生缓存传输在本次响应增加 `Server-Timing: weq-remote-source;desc="cache"` 或 `desc="network"`，标识不进入缓存副本；浏览器自身缓存命中优先于保留在缓存响应中的旧标识。缺少原生标识的旧代理响应不计为下载。
- WebKit 内存命中可能把尺寸和 deliveryType 都留空：仅在资源真实 load 回执成功、无 Service Worker、同源 timing 满足 `fetchStart=requestStart>0`、`responseStart=0`、`responseEnd>=fetchStart` 且三项尺寸全零时识别为空网络指标的内存复用；没有 timing、跨源／重定向导致指标不可见、只有全零尺寸或只有 load 回执都不据此猜来源。依据为 [Resource Timing](https://www.w3.org/TR/resource-timing/)、[WebKit 内存缓存 timing 生成](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/loader/cache/CachedResourceLoader.cpp)、[WebKit timing 字段实现](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/PerformanceResourceTiming.cpp)，另以真实浏览器和独立服务器请求计数回归核对。
- 这里的下载值是已确认资源响应的浏览器接收计量，不是整条连接总流量，不包含 HTML、API、媒体、HTTP 头或 TLS；部分 WebKit 的 HTTP/1.1 分块响应计量包含分块帧，不能强行用清单值覆盖。资源准备可与恢复检查并行，文档提交及后到资源回执不覆盖网页已报告的实际阶段，资源 100% 也不替代界面就绪。
- 新导航清零，网页终止状态断开观察，销毁 WebView 清除回调。旧电脑缺少清单时使用原有不定进度，不猜总大小。该能力需更新电脑服务和手机 App，不修改邀请、授权及网络协议。

资源来源回归可通过 `node scripts/check-web-resource-timing.mjs` 运行：复用已安装的 Playwright（可用 `WEQ_PLAYWRIGHT_IMPORT` 指定模块），`WEQ_CHROMIUM_EXECUTABLE`／`WEQ_WEBKIT_EXECUTABLE` 可指定兼容浏览器。夹具仅监听回环，用独立的 HTTP 请求计数核对冷加载、无变化、仅小文件变化和分块响应；不访问 QQ，不为测试自动下载浏览器。此显示修正兼容现有电脑清单，只需更新手机 App；首次接入资源进度桥仍需配套电脑服务。

## 版本与测试

Android 本地代理按电脑授权持久保存回环端口；同一授权的连接路径变化不改变网页 origin，重连仍生成新的本地 Cookie 秘密，Host／Origin／Cookie 检查不变。端口占用不回退随机端口。端口映射属于 Android 本机存储实现，不新增电脑接口、邀请版本或同步协议，也不修改 iOS 原生端。共用 Web 的业务缓存与加载顺序由 WeQ 仓库维护。

开发源码的加载优化不改变邀请与授权协议：iOS 按电脑／授权／证书标识持久 Web 数据存储；Android 对完整 immutable JS/CSS 使用跨进程代码缓存，同时流式转发响应体。电脑 HTTPS 入口与 Android 原生传输协商 HTTP/2，旧服务仍可使用 HTTP/1.1。电脑 Web 自身合并启动读取并拆分非必要模块，手机不另建业务 API 定义。

Android 在完整接收响应后立即提供内存缓存，后台分批写盘和淘汰。磁盘命中校验通过后进入有界内存缓存，忘记电脑或撤销授权时取消待写缓存并清除文件。

同一已验证设备授权的 Android 代码缓存不再按上游地址分桶，仅复用 `public, immutable` 且带内容哈希的 JS/CSS；WebView 端口、授权检查及其他响应不变。iOS 使用按授权固定的环回 WKWebView 来源，主框架仍可使用 `weqBusinessCache` 本地桥将目录、已打开的近期聊天尾窗和小头像另存到同一授权的有界本地存储。两边来源各自保留原缓存；桥不可用时正常连接，缺失数据按现有途径获取，撤销或忘记电脑时清理共享缓存。JS/CSS 不经 iOS 本地桥，不变更邀请或鉴权协议。

iOS 新壳通过主框架的 `weqRemoteBusinessRecords === 1` 宣告支持目录和近期消息的增量镜像。网页调用 `putRecords` 提交 `scope`、`kind`、`savedAt`、`revision`、有序 `keys` 和变动的 `{key, payload}`。`payload` 是单条查询的 SuperJSON 文本。携带 `base` 时必须匹配原生当前修订，收到 `needsFull` 后可省略 `base` 重送完整记录。成功返回 `stored`，已有更新数据返回 `unchanged`，超限、撤销或读写不可用时返回 `unavailable`。完整记录先落盘，再原子替换清单；同一分区的旧格式和新格式共用数量与空间预算。`getRecords` 按原来的 `newerThan` 返回更新的记录或旧快照。旧壳继续使用 `get` / `put`；旧网页在新壳仍可使用已有旧快照，最新增量需新版网页。小头像沿用原桥。

手机 App 和电脑 WeQ 使用各自语义化版本，不要求版本号相同。当前开发版新增 v4，并继续兼容邀请 v1/v2/v3、状态协议 1 和完整 Web 授权；已发布的 0.1.0 不会因电脑更新而自动获得 v4 解析能力，需要更新手机 App。不兼容变更必须显式增加协议版本，并先给用户可理解的升级错误，不静默接受未知版本。

跨仓库测试约定：电脑 checkout 提供 `scripts/remote-integration-server.ts`，`GET /test/contract` 返回：

```json
{"fixture":1,"protocol":1,"invitationVersions":[1,2,3,4]}
```

其他测试控制入口为 `/test/invitation`、`/test/network`、`/test/devices`、`POST /test/revoke`；仅存在于回环合成服务，不能作为产品鉴权后门。测试网页和真实电脑侧配对实现由桌面仓库维护，手机端通过进程 / HTTP 入口使用，不再越过仓库边界直接 import。

日常协议单测保持完全离线；跨仓库夹具验证使用本机回环，隔离 TS 网络使用专用控制面 / DERP，不注册公共网络。构建通过不等于已完成真机、蜂窝切网或长期性能验收。
