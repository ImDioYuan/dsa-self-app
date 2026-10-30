import SwiftData
import SwiftUI

/// 设置（底部的「设置」标签）：首页只是一列入口，右边是简短的状态，点进去再改。
/// 「功能」里的今日、记账、新闻和底部的页面一一对应
struct SettingsView: View {
    let sync: TaskSyncService

    @AppStorage(SettingsKey.workerURL) private var workerURL = ""
    @AppStorage(ThemeStore.appearanceKey, store: ThemeStore.defaults) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(NewsLanguage.storageKey) private var newsLanguageRaw = NewsLanguage.zh.rawValue
    @State private var hasToken = !(AppSettings.workerToken ?? "").isEmpty
    @State private var gmailSignedIn = GoogleAuth.isSignedIn
    @State private var gmailEmail = GoogleAuth.tokens?.email
    @State private var config = ConfigStore.shared
    @State private var router = AppRouter.shared
    @State private var setup = SetupStatus()
    @Environment(\.modelContext) private var context

    /// 个人资料、AI 模型、新闻存在 Worker 上，没填好 Worker 时点不了
    private var workerReady: Bool { !workerURL.isEmpty && hasToken }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    row("用前配置", icon: "checklist", value: setupSummary) {
                        SetupGuideView()
                    }
                    .tourTarget(.setupRow)
                }

                Section {
                    row("个人资料", icon: "person.crop.circle", value: config.saved?.name ?? "") {
                        ProfileSettingsView()
                    }
                    .disabled(!workerReady)
                    row("外观", icon: "paintpalette", value: (AppearanceMode(rawValue: appearanceRaw) ?? .system).title) {
                        AppearanceSettingsView()
                    }
                }

                Section("连接") {
                    row("Worker", icon: "cloud", value: workerReady ? "已设置" : "未设置") {
                        WorkerSettingsView()
                    }
                    row("AI 模型", icon: "cpu") {
                        AISettingsView()
                    }
                    .disabled(!workerReady)
                    row("Gmail", icon: "envelope", value: gmailSignedIn ? (gmailEmail ?? "已登录") : "未登录") {
                        GmailSettingsView(sync: sync)
                    }
                }

                Section("功能") {
                    row("今日", icon: "checklist", value: "日历 · 提醒 · 邮件规则") {
                        TodaySettingsView(sync: sync)
                    }
                    row("记账", icon: "creditcard", value: "自动记账 · 快捷方式") {
                        LedgerSettingsView()
                    }
                    row("新闻", icon: "newspaper", value: "\((NewsLanguage(rawValue: newsLanguageRaw) ?? .zh).title) · 兴趣 · 城市") {
                        NewsSettingsView()
                    }
                    .disabled(!workerReady)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .navigationDestination(isPresented: $router.showSetupGuide) { SetupGuideView() }
            .navigationDestination(isPresented: $router.showGmailSettings) { GmailSettingsView(sync: sync) }
            // 从 Worker、Gmail 页回来时更新右边的状态
            .onAppear(perform: refresh)
            .task(id: workerReady) {
                if workerReady { await config.loadIfNeeded() }
                refresh()
            }
        }
    }

    private func row<Destination: View>(
        _ title: String,
        icon: String,
        value: String = "",
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink(destination: destination) {
            LabeledContent {
                Text(value).lineLimit(1)
            } label: {
                Label(title, systemImage: icon)
            }
        }
    }

    private var setupSummary: String {
        let missing = setup.missingRequired.count
        return missing == 0 ? "已完成" : "必需还差 \(missing) 步"
    }

    private func refresh() {
        hasToken = !(AppSettings.workerToken ?? "").isEmpty
        gmailSignedIn = GoogleAuth.isSignedIn
        gmailEmail = GoogleAuth.tokens?.email
        setup = .current(context: context)
    }
}

// MARK: - Worker：地址、口令、测试连接

struct WorkerSettingsView: View {
    var body: some View {
        Form {
            WorkerConnectionSection()

            Section {
                NavigationLink("怎么部署") { SetupStepView(step: .deployWorker, showsSettingsLink: false) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Worker")
    }
}

/// 地址、口令和「测试连接」。设置 → Worker 和新手引导共用；连上后顺便读取 Worker 上的配置
struct WorkerConnectionSection: View {
    var footer = "你自己部署的 Cloudflare Worker。"

    @AppStorage(SettingsKey.workerURL) private var workerURL = ""
    @State private var token = AppSettings.workerToken ?? ""
    @State private var status: Status = .idle
    @FocusState private var editingToken: Bool

    enum Status: Equatable {
        case idle, checking, ok
        case failed(String)
    }

    var body: some View {
        Section {
            TextField("https://dsa-worker.<你的账号>.workers.dev", text: $workerURL)
                .urlInput()
            // 不用 SecureField：系统会把地址和口令当成用户名和密码，离开页面时弹「存储密码」。
            // 改成普通输入框，不在输入时用圆点盖住
            TextField("访问口令 APP_TOKEN", text: $token)
                .urlInput()
                .focused($editingToken)
                .foregroundStyle(editingToken ? Color.primary : Color.clear)
                .overlay(alignment: .leading) {
                    if !editingToken, !token.isEmpty {
                        Text(String(repeating: "•", count: min(token.count, 24)))
                            .lineLimit(1)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: token) { _, newValue in AppSettings.workerToken = newValue }
            HStack {
                Button("测试连接", action: check)
                    .disabled(workerURL.isEmpty || token.isEmpty || status == .checking)
                Spacer()
                statusLabel
            }
        } footer: {
            Text(footer)
        }
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .ok: StepStateView(state: .done("已连接"))
        case let .failed(message): Text(message).foregroundStyle(.red).font(.footnote).lineLimit(2)
        }
    }

    private func check() {
        status = .checking
        Task {
            do {
                try await DSAClient.fromSettings().health()
                status = .ok
                await ConfigStore.shared.load()
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
