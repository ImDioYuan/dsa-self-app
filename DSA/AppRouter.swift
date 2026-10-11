import Observation
import SwiftUI

/// 全局导航：快捷指令、控制中心、相机按钮等外部入口通过它切换页面、弹出记一笔
@MainActor
@Observable
final class AppRouter {
    static let shared = AppRouter()

    enum AppTab: Hashable {
        case tasks, ledger, news, settings
    }

    var tab: AppTab = .tasks
    /// 有值时记账页会弹出「记一笔」并带入这些内容
    var pendingDraft: EntryDraft?
    /// 相机按钮拍的小票照片，记账页拿到后自动识别
    var pendingReceipt: Data?

    private init() {}

    /// 切到记账页并弹出记一笔
    func quickAdd(_ draft: EntryDraft = EntryDraft()) {
        tab = .ledger
        pendingDraft = draft
    }

    /// 切到记账页并识别这张小票
    func scanReceipt(_ image: Data) {
        tab = .ledger
        pendingReceipt = image
    }

    /// 小组件里的链接：dsa://ledger、dsa://add
    func open(_ url: URL) {
        guard url.scheme == "dsa" else { return }
        switch url.host() {
        case "add": quickAdd()
        case "ledger": tab = .ledger
        case "tasks": tab = .tasks
        default: break
        }
    }
}
