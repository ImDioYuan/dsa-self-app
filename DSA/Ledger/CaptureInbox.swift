#if canImport(LockedCameraCapture)
import Foundation
import LockedCameraCapture

/// 相机按钮 / 锁屏拍摄扩展拍完后打开 app，从这里取照片
@MainActor
enum CaptureInbox {
    static func handle(_ activity: NSUserActivity) {
        let action = activity.userInfo?[CaptureAction.key] as? String
        Task {
            if action == CaptureAction.quickAdd {
                AppRouter.shared.quickAdd()
            } else if let image = latestImage() {
                AppRouter.shared.scanReceipt(image)
            }
            await clear()
        }
    }

    /// 所有拍摄会话目录里最新的一张照片
    static func latestImage() -> Data? {
        let fm = FileManager.default
        var newest: (date: Date, url: URL)?
        for directory in LockedCameraCaptureManager.shared.sessionContentURLs {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
            for file in files where ["jpg", "jpeg", "heic", "png"].contains(file.pathExtension.lowercased()) {
                let date = (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                if newest == nil || date > newest!.date { newest = (date, file) }
            }
        }
        return newest.flatMap { try? Data(contentsOf: $0.url) }
    }

    /// 照片已经读进 app，清掉拍摄会话目录
    static func clear() async {
        for directory in LockedCameraCaptureManager.shared.sessionContentURLs {
            try? await LockedCameraCaptureManager.shared.invalidateSessionContent(at: directory)
        }
    }
}
#endif
