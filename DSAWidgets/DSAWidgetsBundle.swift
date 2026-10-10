import SwiftUI
import WidgetKit

@main
struct DSAWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TodaySpendWidget()
        QuickAddControl()
        CaptureReceiptControl()
    }
}

// MARK: - 控制中心 / 锁屏按钮

/// 控制中心「记一笔」：打开 DSA 弹出记一笔
struct QuickAddControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.dio.dsa.control.quickadd") {
            ControlWidgetButton(action: QuickAddIntent()) {
                Label("记一笔", systemImage: "plus.circle")
            }
        }
        .displayName("记一笔")
        .description("打开 DSA 记一笔")
    }
}

/// 控制中心「拍小票」：打开 DSA 的小票相机（锁屏也能用）
struct CaptureReceiptControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.dio.dsa.control.capture") {
            ControlWidgetButton(action: CaptureReceiptIntent()) {
                Label("拍小票", systemImage: "doc.text.viewfinder")
            }
        }
        .displayName("拍小票记账")
        .description("打开 DSA 的小票相机")
    }
}
