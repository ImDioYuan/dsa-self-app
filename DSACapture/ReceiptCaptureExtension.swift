import AVFoundation
import AVKit
import ExtensionKit
import Foundation
import LockedCameraCapture
import SwiftUI

/// 相机按钮 / 锁屏「拍小票」启动的拍摄扩展。
/// 扩展不能访问 app 的数据库，只能把照片放进 session 目录，再请求打开 app 处理。
@main
struct ReceiptCaptureExtension: LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            ReceiptCaptureScreen(session: session)
        }
    }
}

/// 自己画的相机界面：全黑底（启动不闪白）、底部「记一笔 · 快门 · 闪光灯」
struct ReceiptCaptureScreen: View {
    let session: LockedCameraCaptureSession

    /// 创建时就在后台开始启动相机（已授权的情况下），不等界面画完
    @State private var camera = CameraController()
    @State private var flashOn = false
    @State private var busy = false
    @State private var shutterBlink = false
    @State private var denied = false
    /// 相机出第一帧后才显示取景画面（淡入），之前显示深色底 + 取景框
    @State private var live = false

    var body: some View {
        ZStack {
            // 等待相机的这零点几秒：不是纯黑，而是很暗的柔和渐变，和取景框一起像相机正在对焦
            RadialGradient(colors: [Color(white: 0.17), Color(white: 0.04)], center: .center, startRadius: 20, endRadius: 520)
                .ignoresSafeArea()

            CameraPreview(controller: camera)
                .ignoresSafeArea()
                .opacity(live ? (shutterBlink ? 0.2 : 1) : 0)
                .animation(.easeOut(duration: 0.35), value: live)

            // 小票取景框：一直显示，帮助对准
            ViewfinderFrame()
                .padding(.horizontal, 36)
                .padding(.top, 70)
                .padding(.bottom, 170)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                Text(denied ? "请在设置里允许 DSA 使用相机" : "对准小票，按快门或相机按钮")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.top, 16)

                Spacer()

                HStack(alignment: .center) {
                    // 左：不拍照，直接记一笔（苹果相机放相册缩略图的位置）
                    CircleButton(systemImage: "square.and.pencil", label: "记一笔") {
                        openApp(action: CaptureAction.quickAdd)
                    }
                    Spacer()
                    ShutterButton(busy: busy, action: shoot)
                    Spacer()
                    // 右：闪光灯
                    CircleButton(systemImage: flashOn ? "bolt.fill" : "bolt.slash.fill", label: flashOn ? "闪光开" : "闪光关") {
                        flashOn.toggle()
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
            }

            if busy {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("正在打开 DSA…").font(.subheadline).foregroundStyle(.white)
                }
                .padding(24)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
        .preferredColorScheme(.dark)
        .task {
            denied = !(await CameraController.requestAccess())
            guard !denied else { return }
            camera.start()
            // 兜底：万一错过了「开始运行」通知，1.5 秒后也显示画面
            try? await Task.sleep(for: .seconds(1.5))
            live = true
        }
        // 相机开始出画面；稍等一下让自动曝光稳定，避免先闪一下暗画面
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.didStartRunningNotification, object: camera.session)) { _ in
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                live = true
            }
        }
        .onAppear {
            // 相机可能在界面出现前就已经启动好了
            if camera.session.isRunning { live = true }
        }
        .onDisappear { camera.stop() }
        // 相机按钮、音量键按下松开时拍照
        .onCameraCaptureEvent { event in
            if event.phase == .ended { shoot() }
        }
    }

    private func shoot() {
        guard !busy, !denied else { return }
        busy = true
        withAnimation(.easeOut(duration: 0.08)) { shutterBlink = true }
        withAnimation(.easeIn(duration: 0.2).delay(0.08)) { shutterBlink = false }

        let directory = session.sessionContentURL
        camera.capture(flash: flashOn) { data in
            Task { @MainActor in
                guard let data else { busy = false; return }
                let file = directory.appending(path: "receipt-\(UUID().uuidString).jpg")
                do {
                    try data.write(to: file)
                    openApp(action: CaptureAction.receipt)
                } catch {
                    busy = false
                }
            }
        }
    }

    /// 打开 DSA（锁屏时系统会先要求解锁）
    private func openApp(action: String) {
        let session = session
        Task {
            let activity = NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture)
            activity.userInfo = [CaptureAction.key: action]
            do {
                try await session.openApplication(for: activity)
            } catch {
                busy = false
            }
        }
    }
}

// MARK: - 取景框

/// 四个圆角直角标记，类似文档扫描的对准框
private struct ViewfinderFrame: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let arm: CGFloat = 26, radius: CGFloat = 14
            Path { p in
                // 左上
                p.move(to: CGPoint(x: 0, y: arm + radius))
                p.addLine(to: CGPoint(x: 0, y: radius))
                p.addQuadCurve(to: CGPoint(x: radius, y: 0), control: .zero)
                p.addLine(to: CGPoint(x: arm + radius, y: 0))
                // 右上
                p.move(to: CGPoint(x: w - arm - radius, y: 0))
                p.addLine(to: CGPoint(x: w - radius, y: 0))
                p.addQuadCurve(to: CGPoint(x: w, y: radius), control: CGPoint(x: w, y: 0))
                p.addLine(to: CGPoint(x: w, y: arm + radius))
                // 右下
                p.move(to: CGPoint(x: w, y: h - arm - radius))
                p.addLine(to: CGPoint(x: w, y: h - radius))
                p.addQuadCurve(to: CGPoint(x: w - radius, y: h), control: CGPoint(x: w, y: h))
                p.addLine(to: CGPoint(x: w - arm - radius, y: h))
                // 左下
                p.move(to: CGPoint(x: arm + radius, y: h))
                p.addLine(to: CGPoint(x: radius, y: h))
                p.addQuadCurve(to: CGPoint(x: 0, y: h - radius), control: CGPoint(x: 0, y: h))
                p.addLine(to: CGPoint(x: 0, y: h - arm - radius))
            }
            .stroke(.white.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .shadow(color: .black.opacity(0.35), radius: 3)
        }
    }
}

// MARK: - 按钮

private struct ShutterButton: View {
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                Circle().fill(.white).frame(width: 64, height: 64).scaleEffect(busy ? 0.85 : 1)
            }
            .animation(.spring(duration: 0.25), value: busy)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("拍照")
    }
}

private struct CircleButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .glassEffect(.regular.interactive(), in: .circle)
                Text(label).font(.caption2).foregroundStyle(.white.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 相机

/// 取景框
private struct CameraPreview: UIViewRepresentable {
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = controller.session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// AVCaptureSession 的封装。所有会话操作都在自己的串行队列上执行
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "dsa.capture.session")
    private var configured = false
    private var completion: (@Sendable (Data?) -> Void)?

    override init() {
        super.init()
        // 已经授权过就立刻在后台配置并启动相机，和界面渲染同时进行，省掉零点几秒等待
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { start() }
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.maxPhotoQualityPrioritization = .balanced
        }
        session.commitConfiguration()
        configured = true
    }

    func capture(flash: Bool, completion: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            guard configured, session.isRunning else { completion(nil); return }
            let settings = output.availablePhotoCodecTypes.contains(.jpeg)
                ? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
                : AVCapturePhotoSettings()
            if flash, output.supportedFlashModes.contains(.on) { settings.flashMode = .on }
            // 竖拍：照片方向和取景框一致
            if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.completion = completion
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        queue.async { [self] in
            completion?(data)
            completion = nil
        }
    }
}
