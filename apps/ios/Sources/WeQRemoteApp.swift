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
                    if scenePhase == .background {
                        model.disconnect()
                        model.resumeReconnect()
                        await network.stop(disable: false)
                    } else if scenePhase == .active {
                        while !Task.isCancelled {
                            if !model.testMode && EmbeddedNetwork.integrationControl == nil && !ProcessInfo.processInfo.arguments.contains("--remote-web-smoke-test") { await model.reconnect() }
                            if model.connected { return }
                            do { try await Task.sleep(for: .seconds(5)) } catch { return }
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
    @State private var pairingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            if let session = model.webSession {
                WebContainer(session: session)
                    // 后台可能合并中间的 nil 状态，新会话不能复用旧的 WKWebView。
                    .id(ObjectIdentifier(session))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button { model.disconnect() } label: { Image(systemName: "xmark") }.accessibilityLabel("断开电脑") } }
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { session.view.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("重新加载") } }
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(role: .destructive) { model.forget() } label: { Image(systemName: "trash") }.accessibilityLabel("删除电脑") } }
            } else {
            Form {
                if model.code == nil {
                    Section("配对电脑") {
                        TextField("配对链接", text: $model.invitationText, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .lineLimit(1...3).privacySensitive().accessibilityIdentifier("pairingLink")
                            .submitLabel(.go)
                            .onSubmit { pairingTask = Task { await model.pair() } }
                            .onChange(of: model.invitationText) { _, value in if !value.isEmpty { model.preparePairing() } }
                        HStack {
                            Button { Task { await scan() } } label: { Label("扫码", systemImage: "qrcode.viewfinder") }
                            Spacer()
                            if !model.invitationText.isEmpty {
                                Button { pairingTask = Task { await model.pair() } } label: { Image(systemName: "arrow.right") }
                                    .accessibilityLabel("连接电脑").accessibilityIdentifier("pairComputer")
                                    .disabled(model.busy)
                            }
                        }.buttonStyle(.borderless)
                    }
                }
                if model.message != "未配对" || model.error != nil || model.busy {
                Section("电脑") {
                    Label(model.message, systemImage: model.connected ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                        .foregroundStyle(model.connected ? Color.green : Color.primary)
                        .accessibilityIdentifier("computerState")
                    if let host = model.computerAddress { LabeledContent("地址", value: host).font(.caption) }
                    if let code = model.code {
                        LabeledContent("校验码") { Text(code).font(.title2.monospacedDigit()).textSelection(.enabled) }
                        Text("等待电脑批准").foregroundStyle(.secondary)
                    }
                    if model.paired && model.testMode {
                        Button { Task { await model.refresh() } } label: { Label("验证连通", systemImage: "arrow.clockwise") }
                            .disabled(model.busy).accessibilityIdentifier("verifyConnection")
                    }
                    if model.paired {
                        Button("删除电脑", role: .destructive) { model.forget() }
                    }
                    if model.busy { ProgressView().accessibilityLabel("请求进行中") }
                    if let error = model.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("connectionError") }
                }
                }
            }
            .navigationTitle("WeQ Remote")
            .onChange(of: scenePhase) { _, phase in if phase == .background { pairingTask?.cancel() } }
            .onDisappear { pairingTask?.cancel() }
            .task { if EmbeddedNetwork.integrationControl != nil { await network.start() } }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    ScannerView(onScan: { model.invitationText = $0; scanning = false; pairingTask = Task { await model.pair() } }, onError: { scanning = false; cameraError = true })
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("扫描配对码").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { scanning = false } } }
                }
            }
            .alert("相机不可用", isPresented: $cameraError) { Button("好", role: .cancel) {} }
                message: { Text("可在系统设置中允许相机访问，或粘贴电脑的配对链接。") }
            }
        }
    }

    private func scan() async {
        model.preparePairing()
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        if allowed && DataScannerViewController.isSupported && DataScannerViewController.isAvailable { scanning = true }
        else { cameraError = true }
    }
}
