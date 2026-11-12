import AVFoundation
import SwiftUI
import VisionKit

@main
struct WeQRemoteApp: App {
    @StateObject private var network: EmbeddedNetwork
    @StateObject private var model: RemoteModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let network = EmbeddedNetwork()
        _network = StateObject(wrappedValue: network)
        _model = StateObject(wrappedValue: RemoteModel(network: network))
    }

    var body: some Scene {
        WindowGroup {
            RemoteView(model: model, network: network)
                .task {
                    #if DEBUG && targetEnvironment(simulator)
                    await WebSmoke.run(model: model, network: network)
                    #endif
                }
                .onOpenURL { url in model.invitationText = url.absoluteString; Task { await model.pair() } }
                .task(id: scenePhase) {
                    if scenePhase == .active { await model.monitorConnectionHealth() }
                }
                .task(id: scenePhase) {
                    if scenePhase == .background {
                        model.suspend()
                        if model.webSession == nil { await network.stop(disable: false) }
                    } else if scenePhase == .active {
                        while !Task.isCancelled {
                            if !model.testMode && EmbeddedNetwork.integrationControl == nil && !ProcessInfo.processInfo.arguments.contains("--remote-web-smoke-test") { await model.reconnect() }
                            if model.error != nil && !model.rememberedComputer && model.webSession == nil { return }
                            do { try await Task.sleep(for: .seconds(model.webReady ? model.connectionCheckInterval : model.connected ? 15 : 5)) } catch { return }
                        }
                    }
                }
        }
    }
}

struct RemoteView: View {
    @ObservedObject var model: RemoteModel
    @ObservedObject var network: EmbeddedNetwork
    @Environment(\.scenePhase) private var scenePhase
    @State private var scanning = false
    @State private var cameraError = false
    @State private var confirmingDelete = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pairingTask: Task<Void, Never>?
    private let actionColor = Color(red: 0.02, green: 0.48, blue: 0.43)
    // 深色下用亮色强调色填充按钮并配深色文字，和浅色下的深青底白字互为镜像。
    private var actionFill: Color { colorScheme == .dark ? accent : actionColor }
    private var actionInk: Color { colorScheme == .dark ? Color(red: 0.05, green: 0.14, blue: 0.12) : .white }
    private var accent: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.36, green: 0.83, blue: 0.75, alpha: 1) : UIColor(red: 0.02, green: 0.48, blue: 0.43, alpha: 1) })
    }

    // 网页加载出来之前留在连接页，用原生进度替代空白的全屏网页。
    private var loadingStage: String? {
        if model.webSession != nil, !model.webReady { return model.webLoadingStage }
        if model.code != nil { return "等待电脑确认" }
        if model.busy { return model.paired ? "正在验证电脑授权" : "正在连接电脑" }
        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
            if let session = model.webSession {
                // 页面加载完成后才进入全屏网页；不显示任何原生栏或按钮。
                WebContainer(session: session)
                    .id(ObjectIdentifier(session))
                    .ignoresSafeArea()
                    .toolbar(.hidden, for: .navigationBar)
                    .opacity(model.webReady ? 1 : 0)
                    .allowsHitTesting(model.webReady)
                    .accessibilityHidden(!model.webReady)
            }
            if !model.webReady {
                connectionPage
                    .transition(.opacity)
            }
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.18), value: model.webReady)
        .tint(accent)
        .sheet(isPresented: $model.showingDetails) { detailsSheet }
    }

    private var detailsSheet: some View {
        NavigationStack {
            List {
                Section("连接详情") {
                    Text(model.connectionDetails).font(.subheadline).textSelection(.enabled)
                    if model.paired {
                        Button("立即检查") { Task { await model.reconnect() } }.disabled(model.busy)
                    }
                    if let session = model.webSession, model.webReady {
                        Button("重新加载") { model.showingDetails = false; session.reload() }
                        Button("断开连接") {
                            model.showingDetails = false
                            model.disconnect()
                            Task { await network.stop() }
                        }
                    }
                }
                Section("软件更新") {
                    Toggle("检查测试版", isOn: Binding(get: { model.includePrerelease }, set: { model.setPrerelease($0) }))
                        .disabled(model.checkingUpdates)
                    Button { Task { await model.checkUpdates() } } label: {
                        Label(model.checkingUpdates ? "正在检查更新…" : "检查更新", systemImage: "arrow.triangle.2.circlepath")
                    }.disabled(model.checkingUpdates)
                    Text(model.updateMessage).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(Array(model.updateDownloads.prefix(3).enumerated()), id: \.offset) { index, mirror in
                        Link(index == 0 ? "下载更新（\(mirror.label)）" : "备用下载（\(mirror.label)）", destination: mirror.downloadURL)
                    }
                    if let url = model.releaseURL { Link("查看发布说明", destination: url) }
                }
            }
            .navigationTitle("更多").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { model.showingDetails = false } } }
        }.tint(accent)
    }

    // 首页是三段式：顶部状态条、居中状态区、底部操作坞。内容不再全挤在顶部。
    private var connectionPage: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    topBar.padding(.top, 8)
                    Spacer(minLength: 28)
                    hero
                    Spacer(minLength: 32)
                    dock
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
                .frame(minHeight: proxy.size.height - 18)
                .frame(maxWidth: 496)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: scenePhase) { _, phase in if phase == .background { pairingTask?.cancel() } }
        .onDisappear { pairingTask?.cancel() }
        .task { if EmbeddedNetwork.integrationControl != nil { await network.start() } }
        .sheet(isPresented: $scanning) {
            NavigationStack {
                ScannerView(onScan: { model.invitationText = $0; scanning = false; pair() }, onError: { scanning = false; cameraError = true })
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("扫描配对码").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { scanning = false } } }
            }
        }
        .alert("相机不可用", isPresented: $cameraError) { Button("好", role: .cancel) {} }
            message: { Text("可在系统设置中允许相机访问，或粘贴电脑的配对链接。") }
        .alert("删除电脑？", isPresented: $confirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除电脑", role: .destructive) { model.forget(); Task { await network.stop() } }
        } message: { Text("将清除本机保存的电脑连接，下次需要重新扫码并在电脑上批准。电脑上的设备授权不会撤销。") }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text("WeQ Remote")
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 8)
            statusPill
            Button { model.showingDetails = true } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel("更多")
            .accessibilityIdentifier("connectionMenu")
        }
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(statusTint).frame(width: 6, height: 6)
            Text(statusText).font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(uiColor: .separator).opacity(0.5), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connectionStatus")
    }

    private var statusText: String {
        if model.code != nil { return "等待批准" }
        if model.busy || loadingStage != nil { return model.paired ? "正在进入" : "连接中" }
        if model.paired { return "已连接" }
        return "未连接"
    }

    private var statusTint: Color {
        (model.code != nil || model.busy || loadingStage != nil || model.paired) ? accent : Color(uiColor: .tertiaryLabel)
    }

    private var heroTitle: String {
        if model.webSession != nil, !model.webReady, model.webDownload?.downloading == true { return "正在下载网页资源" }
        if let stage = loadingStage { return stage }
        if model.error != nil { return "连接未通过" }
        if model.rememberedComputer { return "我的电脑" }
        return "连接电脑"
    }

    private var heroDetail: String {
        if model.code != nil { return "在电脑上核对校验码，并允许这台手机访问" }
        if model.webSession != nil, !model.webReady {
            if let progress = model.webDownload { return progress.detail }
            return model.computerAddress ?? "页面准备好后自动进入"
        }
        if model.busy { return model.computerAddress ?? "正在准备与电脑的连接" }
        if model.error != nil { return model.rememberedComputer ? (model.computerAddress ?? "电脑暂时不可用") : "请确认电脑在线后重试" }
        if model.rememberedComputer { return model.computerAddress ?? "打开后会自动连接上次的电脑" }
        return "在电脑上的 WeQ 生成配对码，扫码或粘贴链接即可连接"
    }

    private var hero: some View {
        VStack(spacing: 20) {
            heroMark
            VStack(spacing: 10) {
                Text(heroTitle)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("computerState")
                Text(heroDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let code = model.code {
                Text(code)
                    .font(.largeTitle.monospaced().weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .textSelection(.enabled)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 14)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(uiColor: .separator).opacity(0.4), lineWidth: 0.5))
                    .accessibilityLabel("校验码 \(code)")
            }
            if let error = model.error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .systemRed))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("connectionError")
            }
            if model.paired && model.testMode {
                Button { Task { await model.refresh() } } label: { Label("验证连通", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .disabled(model.busy)
                    .accessibilityIdentifier("verifyConnection")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectionProgress")
    }

    private var heroMark: some View {
        ZStack {
            Circle()
                .fill(accent.opacity(0.10))
                .frame(width: 108, height: 108)
            Circle()
                .strokeBorder(accent.opacity(0.16), lineWidth: 1)
                .frame(width: 142, height: 142)
            if loadingStage != nil, let progress = model.webDownload, progress.downloading {
                Circle()
                    .trim(from: 0, to: progress.fraction)
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 138, height: 138)
                Text("\(Int((progress.fraction * 100).rounded()))%")
                    .font(.title2.monospacedDigit().weight(.medium))
                    .foregroundStyle(accent)
                    .frame(width: 104, height: 60)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
            } else if loadingStage != nil {
                ProgressView().controlSize(.large).tint(accent)
            } else {
                Image(systemName: model.error != nil ? "exclamationmark.triangle" : "desktopcomputer")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(accent)
            }
        }
        .frame(height: 150)
        .accessibilityHidden(true)
    }

    // 主操作贴近拇指：底部操作坞随状态切换扫码、链接或已保存电脑的入口。
    @ViewBuilder private var dock: some View {
        VStack(spacing: 12) {
            if model.rememberedComputer || model.isConnecting {
                reconnectRow
            } else if canPair {
                scanButton
                linkField
            }
        }
    }

    private var canPair: Bool {
        model.code == nil && !model.rememberedComputer && !model.paired
    }

    private var scanButton: some View {
        Button { Task { await scan() } } label: {
            HStack(spacing: 12) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 21, weight: .medium))
                Text("扫码连接").font(.headline)
            }
            .foregroundStyle(actionInk)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(actionFill, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PressableButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("扫码")
        .disabled(model.busy)
        .opacity(model.busy ? 0.55 : 1)
    }

    private var linkField: some View {
        HStack(spacing: 10) {
            Image(systemName: "link").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            TextField("粘贴配对链接", text: $model.invitationText, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .lineLimit(1...3).privacySensitive().accessibilityIdentifier("pairingLink")
                .font(.body)
                .submitLabel(.go).onSubmit { pair() }
                .onChange(of: model.invitationText) { _, value in if !value.isEmpty { model.preparePairing() } }
            if !model.invitationText.isEmpty {
                Button { pair() } label: {
                    Image(systemName: "arrow.right").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(actionInk)
                        .frame(width: 34, height: 34)
                        .background(actionFill, in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("连接电脑").accessibilityIdentifier("pairComputer").disabled(model.busy)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .frame(minHeight: 54)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5))
    }

    private var reconnectRow: some View {
        HStack(spacing: 12) {
            if model.rememberedComputer {
                Button { Task { await scan() } } label: {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 20, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 52, height: 52)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5))
                }
                .accessibilityLabel("扫码更新连接")
                .accessibilityIdentifier("updateConnection")
            }
            Button {
                if model.isConnecting { stopConnection() }
                else { model.resumeReconnect(); pairingTask = Task { await model.reconnect() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isConnecting ? "stop.fill" : "arrow.right").font(.system(size: 15, weight: .semibold))
                    Text(model.isConnecting ? "停止" : "连接").font(.headline)
                }
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(PressableButtonStyle(reduceMotion: reduceMotion))
            .accessibilityIdentifier("connectComputer")
            Button(role: .destructive) { confirmingDelete = true } label: {
                Image(systemName: "trash").font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(uiColor: .systemRed))
                    .frame(width: 52, height: 52)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5))
            }
            .accessibilityLabel("删除电脑")
        }
    }

    private func pair() { pairingTask = Task { await model.pair() } }

    private func stopConnection() {
        pairingTask?.cancel()
        model.disconnect()
        pairingTask = Task { await network.stop() }
    }

    private func scan() async {
        pairingTask?.cancel()
        if model.rememberedComputer {
            model.disconnect()
            await network.stop()
        } else { model.preparePairing() }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        if allowed && DataScannerViewController.isSupported && DataScannerViewController.isAvailable { scanning = true }
        else { cameraError = true }
    }
}

private struct PressableButtonStyle: ButtonStyle {
    var reduceMotion: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.975 : 1))
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}
