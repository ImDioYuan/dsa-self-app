#if os(iOS)
import SwiftUI
import VisionKit

/// 系统的文档扫描相机：自动找小票边缘、拉正、去阴影
struct DocumentCamera: UIViewControllerRepresentable {
    var onScan: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// VisionKit 在主线程回调
    @MainActor
    final class Coordinator: NSObject, @MainActor VNDocumentCameraViewControllerDelegate {
        let parent: DocumentCamera
        init(parent: DocumentCamera) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            // 只取第一页
            if scan.pageCount > 0, let data = scan.imageOfPage(at: 0).jpegData(compressionQuality: 0.9) {
                parent.onScan(data)
            }
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}
#endif
