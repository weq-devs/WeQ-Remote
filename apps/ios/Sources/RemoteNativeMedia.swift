import AVFoundation
import CoreImage
import UIKit
import WebKit

/** HTTP 网页的设备采集适配；只传本地媒体帧，不复制电脑业务接口。 */
@MainActor
final class RemoteNativeMedia: NSObject, WKScriptMessageHandler {
    static let script = """
    window.weqRemoteMedia={start:function(options){window.webkit.messageHandlers.weqMedia.postMessage(Object.assign({},options,{action:'start'}));},stop:function(id){window.webkit.messageHandlers.weqMedia.postMessage({action:'stop',id:id});}};
    """
    private weak var view: WKWebView?
    private let endpoint: URL
    private var active: [String: WebMediaRequest] = [:]
    private var pending: [String: UUID] = [:]
    private var revision = 0
    private var closed = false
    private var audioInFlight = 0
    private var ready: Set<String> = []
    private var observers: [NSObjectProtocol] = []
    private lazy var capture = RemoteMediaCapture(
        onAudio: { [weak self] data, revision in
            Task { @MainActor in self?.audio(data, revision: revision) }
        },
        onVideo: { [weak self] frame, revision, done in
            Task { @MainActor in
                guard let self, !self.closed, self.revision == revision else { done(); return }
                self.dispatch(self.active.values.filter { $0.video != nil }.map {
                    frame.merging(["id": $0.id, "type": "video"]) { _, new in new }
                }, completion: done)
            }
        },
        onReady: { [weak self] revision in
            Task { @MainActor in
                guard let self, !self.closed, self.revision == revision else { return }
                let ids = Set(self.active.keys).subtracting(self.ready)
                self.ready.formUnion(ids)
                self.dispatch(ids.map { ["id": $0, "type": "ready"] })
            }
        },
        onError: { [weak self] message, revision in
            Task { @MainActor in
                guard let self, self.revision == revision else { return }
                self.stopAll(message: message)
            }
        })

    init(view: WKWebView, endpoint: URL) {
        self.view = view
        self.endpoint = endpoint
        super.init()
        for name in [UIApplication.didEnterBackgroundNotification, AVAudioSession.interruptionNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if notification.name == AVAudioSession.interruptionNotification,
                   (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) != AVAudioSession.InterruptionType.began.rawValue { return }
                Task { @MainActor in self?.stopAll(message: "设备采集已中断，请重新开始") }
            })
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !closed, endpoint.scheme == "http", message.webView === view,
              message.frameInfo.isMainFrame, let url = message.frameInfo.request.url,
              RemoteWebPolicy.sameOrigin(url, endpoint: endpoint),
              let value = message.body as? [String: Any], let id = value["id"] as? String,
              WebMediaRequest.validID(id) else { return }
        if value["action"] as? String == "stop" { stop(id); return }
        guard value["action"] as? String == "start", let request = WebMediaRequest(message: value) else {
            dispatch([["id": id, "type": "error", "message": "设备采集参数无效"]]); return
        }
        stop(id, notify: false)
        guard active.count + pending.count < 4 else {
            dispatch([["id": id, "type": "error", "message": "请先结束其他设备采集"]]); return
        }
        let token = UUID()
        pending[id] = token
        Task { [weak self] in
            let audioAllowed = request.audio ? await Self.permission(.audio) : true
            let videoAllowed = request.video != nil ? await Self.permission(.video) : true
            guard let self, !self.closed, self.pending[id] == token else { return }
            self.pending.removeValue(forKey: id)
            guard audioAllowed, videoAllowed else {
                self.dispatch([["id": id, "type": "error", "message": "请在系统设置中允许 WeQ Remote 使用麦克风和摄像头"]]); return
            }
            if let video = request.video, let existing = self.active.values.compactMap(\.video).first, video != existing {
                self.dispatch([["id": id, "type": "error", "message": "摄像头正在被其他操作使用，请先结束该操作"]]); return
            }
            self.active[id] = request
            self.updateCapture()
        }
    }

    private static func permission(_ media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: media)
        default: return false
        }
    }

    private func updateCapture() {
        revision += 1
        capture.update(audio: active.values.contains { $0.audio },
                       video: active.values.compactMap(\.video).first, revision: revision)
    }

    private func audio(_ data: Data, revision: Int) {
        guard !closed, self.revision == revision else { return }
        let ids = active.values.filter(\.audio).map(\.id)
        guard !ids.isEmpty else { return }
        guard audioInFlight < 8 else {
            for id in ids {
                dispatch([["id": id, "type": "error", "message": "音频处理繁忙，采集已停止，请重试"]])
                stop(id, notify: false)
            }
            return
        }
        let base64 = data.base64EncodedString()
        audioInFlight += 1
        dispatch(ids.map { ["id": $0, "type": "audio", "sampleRate": 16000, "channels": 1, "pcmBase64": base64] }) { [weak self] in
            self?.audioInFlight -= 1
        }
    }

    private func dispatch(_ details: [[String: Any]], completion: @escaping () -> Void = {}) {
        guard !details.isEmpty, let view, let data = try? JSONSerialization.data(withJSONObject: details),
              let json = String(data: data, encoding: .utf8) else { completion(); return }
        view.evaluateJavaScript("for(const detail of \(json)){window.dispatchEvent(new CustomEvent('weq-remote-media',{detail:detail}));}") { _, _ in completion() }
    }

    private func stop(_ id: String, notify: Bool = true) {
        let existed = active.removeValue(forKey: id) != nil || pending[id] != nil
        pending.removeValue(forKey: id)
        ready.remove(id)
        if existed { updateCapture() }
        if existed && notify { dispatch([["id": id, "type": "ended"]]) }
    }

    func stopAll(message: String? = nil) {
        let ids = Set(active.keys).union(pending.keys)
        guard !ids.isEmpty else { return }
        active.removeAll(); pending.removeAll(); ready.removeAll()
        updateCapture()
        dispatch(ids.map { id in
            message.map { ["id": id, "type": "error", "message": $0] } ?? ["id": id, "type": "ended"]
        })
    }

    func close() {
        guard !closed else { return }
        stopAll()
        closed = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        view = nil
    }
}

/** AVFoundation 操作串行化；视频只保留一个尚未交给网页的帧。 */
private final class RemoteMediaCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "io.github.weqdevs.remote.capture")
    private let engine = AVAudioEngine()
    private var encoder = WebMediaPCMEncoder()
    private var audioActive = false
    private var audioSessionActive = false
    private var camera: AVCaptureSession?
    private var videoOptions: WebMediaRequest.Video?
    private var videoConnection: AVCaptureConnection?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var cameraObservers: [NSObjectProtocol] = []
    private var revision = 0
    private var videoInFlight = false
    private var lastVideoTime = 0.0
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onAudio: (Data, Int) -> Void
    private let onVideo: ([String: Any], Int, @escaping () -> Void) -> Void
    private let onError: (String, Int) -> Void
    private let onReady: (Int) -> Void

    init(onAudio: @escaping (Data, Int) -> Void,
         onVideo: @escaping ([String: Any], Int, @escaping () -> Void) -> Void,
         onReady: @escaping (Int) -> Void,
         onError: @escaping (String, Int) -> Void) {
        self.onAudio = onAudio; self.onVideo = onVideo; self.onReady = onReady; self.onError = onError
    }

    func update(audio: Bool, video: WebMediaRequest.Video?, revision: Int) {
        queue.async {
            self.revision = revision
            do {
                if audio != self.audioActive {
                    if audio { try self.startAudio() } else { self.stopAudio() }
                }
                if video != self.videoOptions {
                    self.stopVideo()
                    self.videoOptions = nil
                    if let video { try self.startVideo(video) }
                }
                self.onReady(revision)
            } catch {
                self.stopAudio()
                self.stopVideo()
                self.onError("无法启动设备采集：\(error.localizedDescription)", revision)
            }
        }
    }

    private func startAudio() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        audioSessionActive = true
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw RemoteError.response }
        converter.primeMethod = .none
        converter.downmix = true
        encoder = WebMediaPCMEncoder()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, buffer.frameLength > 0,
                  let converted = AVAudioPCMBuffer(pcmFormat: target,
                      frameCapacity: AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16000 / format.sampleRate)) + 32) else { return }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, output in
                if supplied { output.pointee = .noDataNow; return nil }
                supplied = true
                output.pointee = .haveData
                return buffer
            }
            if status == .error {
                self.queue.async {
                    guard self.audioActive else { return }
                    self.stopAudio()
                    self.onError("麦克风音频转换失败，请重新开始", self.revision)
                }
                return
            }
            guard let channel = converted.floatChannelData, converted.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(converted.frameLength)))
            self.queue.async {
                guard self.audioActive else { return }
                for packet in self.encoder.append(samples) { self.onAudio(packet, self.revision) }
            }
        }
        audioActive = true
        do { engine.prepare(); try engine.start() }
        catch { stopAudio(); throw error }
    }

    private func stopAudio() {
        if audioActive {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioActive = false
        encoder = WebMediaPCMEncoder()
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    private func startVideo(_ options: WebMediaRequest.Video) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: options.front ? .front : .back) else { throw RemoteError.response }
        let session = AVCaptureSession()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw RemoteError.response }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RemoteError.response }
        session.addOutput(output)
        if let connection = output.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = options.front
            }
            videoConnection = connection
        }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            self?.queue.async {
                if let connection = self?.videoConnection, connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
            }
        }
        session.commitConfiguration()
        videoOptions = options
        lastVideoTime = 0
        camera = session
        for name in [NSNotification.Name.AVCaptureSessionRuntimeError, NSNotification.Name.AVCaptureSessionWasInterrupted] {
            cameraObservers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self, weak session] _ in
                self?.queue.async {
                    guard let self, self.camera === session, self.videoOptions != nil else { return }
                    self.stopVideo()
                    self.onError("摄像头采集已中断，请重新开始", self.revision)
                }
            })
        }
        session.startRunning()
    }

    private func stopVideo() {
        for observer in cameraObservers { NotificationCenter.default.removeObserver(observer) }
        cameraObservers.removeAll()
        rotationObservation = nil; rotationCoordinator = nil
        camera?.stopRunning(); camera = nil
        videoConnection = nil; videoOptions = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let options = videoOptions, !videoInFlight, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard time.isFinite, time - lastVideoTime >= 1.0 / Double(options.fps) else { return }
        lastVideoTime = time
        let image = CIImage(cvPixelBuffer: pixel)
        let scale = max(CGFloat(options.width) / image.extent.width, CGFloat(options.height) / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let width = CGFloat(options.width), height = CGFloat(options.height)
        let crop = CGRect(x: (scaled.extent.width - width) / 2,
                          y: (scaled.extent.height - height) / 2,
                          width: width, height: height)
        let result = scaled.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        var rgba = Data(count: options.width * options.height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(result, toBitmap: bytes.baseAddress!, rowBytes: options.width * 4,
                           bounds: CGRect(x: 0, y: 0, width: options.width, height: options.height),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        videoInFlight = true
        onVideo(["width": options.width, "height": options.height, "rgbaBase64": rgba.base64EncodedString(), "timestampMs": time * 1000], revision) { [weak self] in
            self?.queue.async { self?.videoInFlight = false }
        }
    }
}
