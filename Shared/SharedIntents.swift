import AppIntents
import Foundation

// 这些 Intent 同时编进 app、小组件扩展、拍摄扩展（系统要求控件用到的 Intent 在 app 里也存在）。
// 真正的逻辑只在 app 进程里运行，扩展里编译成空实现。

/// 打开 DSA 并弹出「记一笔」（操作按钮、Siri、控制中心按钮）
struct QuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "记一笔"
    static let description = IntentDescription("打开 DSA 并弹出「记一笔」")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !WIDGET_EXTENSION && !CAPTURE_EXTENSION
        AppRouter.shared.quickAdd()
        #endif
        return .result()
    }
}

#if os(iOS)
/// 打开 DSA 的小票相机（相机按钮、控制中心、锁屏按钮）。系统会启动拍摄扩展
struct CaptureReceiptIntent: CameraCaptureIntent {
    static let title: LocalizedStringResource = "拍小票记账"
    static let description = IntentDescription("打开 DSA 的小票相机，拍完自动识别金额和分类")

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}
#endif

/// 拍摄扩展打开 app 时，userInfo 里用这个键说明要做什么
enum CaptureAction {
    static let key = "dsaAction"
    /// 拍了小票，去读 session 目录里的照片
    static let receipt = "receipt"
    /// 没拍照，直接记一笔
    static let quickAdd = "quickAdd"
}
