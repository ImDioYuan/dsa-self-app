import SwiftData
import SwiftUI
#if os(iOS)
import BackgroundTasks
import LockedCameraCapture
#endif

@main
struct DSAApp: App {
    /// 和 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 一致
    static let refreshTaskID = (Bundle.main.bundleIdentifier ?? "dsa") + ".refresh"

    static let container: ModelContainer = {
        do {
            return try ModelContainer(for: TaskItem.self, LedgerEntry.self, LedgerCategory.self)
        } catch {
            fatalError("无法创建数据库：\(error)")
        }
    }()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        TaskItem.migrateImportanceScale(in: Self.container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .themedTint()
                // 日期、日期选择器统一显示中文，不跟随系统语言
                .environment(\.locale, Locale(identifier: "zh_CN"))
                // 小组件里的链接
                .onOpenURL { AppRouter.shared.open($0) }
                #if os(iOS)
                // 相机按钮 / 锁屏拍摄扩展拍完小票后打开 app
                .onContinueUserActivity(NSUserActivityTypeLockedCameraCapture) { CaptureInbox.handle($0) }
                #endif
                // 记账数据有变化就更新小组件
                .onReceive(NotificationCenter.default.publisher(for: ModelContext.didSave)) { _ in
                    LedgerSnapshotWriter.update()
                }
        }
        .modelContainer(Self.container)
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                Self.scheduleBackgroundRefresh()
                LedgerSnapshotWriter.update()
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await Self.runBackgroundRefresh()
        }
        #endif
    }

    #if os(iOS)
    /// 系统决定什么时候唤醒，不保证准时；每次运行后再排下一次
    @MainActor
    static func runBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        // 系统给的后台时间用完时，停下同步（没分析完的邮件下次再分析）
        await withTaskCancellationHandler {
            await TaskSyncService.shared.sync(context: container.mainContext)
        } onCancel: {
            Task { @MainActor in TaskSyncService.shared.cancel() }
        }
        await EmailChargeScanner.shared.runIfDue()
        // 早上的简报提前下载好，打开就能看
        await NewsStore.shared.refresh()
    }

    @MainActor
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        // 一小时后，或者明早 8 点（邮件自动记账、新闻简报）——取更早的那个
        let inAnHour = Date.now.addingTimeInterval(60 * 60)
        let nextEight = Calendar.current.nextDate(
            after: .now, matching: DateComponents(hour: EmailChargeScanner.runHour, minute: 0), matchingPolicy: .nextTime
        ) ?? inAnHour
        request.earliestBeginDate = min(inAnHour, nextEight)
        try? BGTaskScheduler.shared.submit(request)
    }
    #endif
}

struct RootView: View {
    @State private var router = AppRouter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        tabs
            // 邮件自动记账：每天 8 点后第一次打开 / 回到前台时检查（当天已检查过就跳过）
            .task { await EmailChargeScanner.shared.runIfDue() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await EmailChargeScanner.shared.runIfDue() } }
            }
    }

    private var tabs: some View {
        TabView(selection: $router.tab) {
            Tab("今日", systemImage: "checklist", value: AppRouter.AppTab.tasks) {
                TasksView()
            }
            Tab("记账", systemImage: "creditcard", value: AppRouter.AppTab.ledger) {
                LedgerView()
            }
            Tab("新闻", systemImage: "newspaper", value: AppRouter.AppTab.news) {
                NewsView()
            }
            Tab("设置", systemImage: "gearshape", value: AppRouter.AppTab.settings) {
                SettingsView(sync: TaskSyncService.shared)
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
