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
                        model.suspend()
                        if model.webSession == nil { await network.stop(disable: false) }
                    } else if scenePhase == .active {
                        while !Task.isCancelled {
                            if !model.testMode && EmbeddedNetwork.integrationControl == nil && !ProcessInfo.processInfo.arguments.contains("--remote-web-smoke-test") { await model.reconnect() }
                            if model.connected || model.error != nil && !model.rememberedComputer { return }
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
    private let actionColor = Color(red: 0.02, green: 0.48, blue: 0.43)
    private var accent: Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.36, green: 0.83, blue: 0.75, alpha: 1) : UIColor(red: 0.02, green: 0.48, blue: 0.43, alpha: 1) })
    }

    var body: some View {
        NavigationStack {
            if let session = model.webSession {
                WebContainer(session: session)
                    .id(ObjectIdentifier(session))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button { model.disconnect(); Task { await network.stop() } } label: { Image(systemName: "xmark") }.accessibilityLabel("断开电脑") } }
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { session.view.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("重新加载") } }
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(role: .destructive) { model.forget(); Task { await network.stop() } } label: { Image(systemName: "trash") }.accessibilityLabel("删除电脑") } }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if let error = model.error { connectionNotice(error) }
                    }
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "desktopcomputer").font(.system(size: 32, weight: .regular)).foregroundStyle(accent)
                            .padding(.bottom, 12).accessibilityHidden(true)
                        Text("WeQ Remote").font(.system(size: 30, weight: .semibold))
                        Text(model.rememberedComputer ? "我的电脑" : "连接电脑").font(.title3).foregroundStyle(.secondary)
                    }.padding(.top, 24)
                    if model.code == nil && !model.rememberedComputer {
                        VStack(alignment: .leading, spacing: 24) {
                            Button { Task { await scan() } } label: {
                                HStack(spacing: 16) {
                                    Image(systemName: "qrcode.viewfinder").font(.system(size: 32))
                                    Text("扫码连接").font(.headline)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right").font(.body)
                                }.padding(20).frame(maxWidth: .infinity, minHeight: 88)
                            }.buttonStyle(.plain).foregroundStyle(.white).background(actionColor, in: RoundedRectangle(cornerRadius: 8))
                                .accessibilityLabel("扫码").disabled(model.busy)
                            VStack(alignment: .leading, spacing: 10) {
                                Text("配对链接").font(.subheadline).foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    TextField("粘贴配对链接", text: $model.invitationText, axis: .vertical)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                        .lineLimit(1...3).privacySensitive().accessibilityIdentifier("pairingLink")
                                        .submitLabel(.go).onSubmit { pair() }
                                        .onChange(of: model.invitationText) { _, value in if !value.isEmpty { model.preparePairing() } }
                                    if !model.invitationText.isEmpty {
                                        Button { pair() } label: { Image(systemName: "arrow.right").frame(width: 44, height: 44) }
                                            .accessibilityLabel("连接电脑").accessibilityIdentifier("pairComputer").disabled(model.busy)
                                    }
                                }.padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(uiColor: .separator).opacity(0.4)))
                            }
                        }
                    }
                    if model.rememberedComputer || model.message != "未配对" || model.error != nil || model.busy {
                        VStack(alignment: .leading, spacing: 16) {
                            Divider()
                            HStack(spacing: 12) {
                                Image(systemName: model.code == nil ? "desktopcomputer" : "lock.shield").foregroundStyle(accent)
                                Text(model.message == "未配对" && model.rememberedComputer ? "等待连接" : model.message)
                                    .font(.headline).accessibilityIdentifier("computerState")
                                Spacer()
                                if model.busy { ProgressView().accessibilityLabel("请求进行中") }
                            }
                            if let host = model.computerAddress { Text(host).font(.subheadline.monospaced()).foregroundStyle(.secondary) }
                            if let code = model.code {
                                Text("校验码").font(.subheadline).foregroundStyle(.secondary)
                                Text(code).font(.system(size: 36, weight: .medium, design: .monospaced)).textSelection(.enabled)
                            }
                            if let error = model.error { Text(error).font(.subheadline).foregroundStyle(.red).accessibilityIdentifier("connectionError") }
                            if model.paired && model.testMode {
                                Button { Task { await model.refresh() } } label: { Label("验证连通", systemImage: "arrow.clockwise") }
                                    .disabled(model.busy).accessibilityIdentifier("verifyConnection")
                            }
                            if model.rememberedComputer {
                                HStack {
                                    Button { model.resumeReconnect(); Task { await model.reconnect() } } label: { Label("重新连接", systemImage: "arrow.clockwise") }.disabled(model.busy)
                                    Spacer()
                                    Button(role: .destructive) { model.forget(); Task { await network.stop() } } label: { Image(systemName: "trash").frame(width: 44, height: 44) }.accessibilityLabel("删除电脑")
                                }
                            }
                        }
                    }
                }.frame(maxWidth: 440, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 32).frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemGroupedBackground)).scrollDismissesKeyboard(.interactively)
            .toolbar(.hidden, for: .navigationBar)
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
        .tint(accent)
    }

    private func pair() { pairingTask = Task { await model.pair() } }

    private func connectionNotice(_ error: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
            Text(error).font(.footnote).accessibilityIdentifier("connectionError")
            Spacer(minLength: 0)
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                .accessibilityLabel("重试连接").disabled(model.busy)
        }.padding(.horizontal, 16).padding(.vertical, 4).background(.regularMaterial)
    }

    private func scan() async {
        model.preparePairing()
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        if allowed && DataScannerViewController.isSupported && DataScannerViewController.isAvailable { scanning = true }
        else { cameraError = true }
    }
}
