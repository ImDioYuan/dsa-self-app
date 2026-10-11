import SwiftUI

/// 设置（底部的「设置」标签）：首页只是一列入口，右边是简短的状态，点进去再改。
/// 「功能」里的今日、记账、新闻和底部的页面一一对应
struct SettingsView: View {
    let sync: TaskSyncService

    @AppStorage(SettingsKey.workerURL) private var workerURL = ""
    @AppStorage(ThemeStore.appearanceKey, store: ThemeStore.defaults) private var appearanceRaw = AppearanceMode.system.rawValue
    @State private var hasToken = !(AppSettings.workerToken ?? "").isEmpty
    @State private var gmailSignedIn = GoogleAuth.isSignedIn
    @State private var gmailEmail = GoogleAuth.tokens?.email
    @State private var config = ConfigStore.shared

    /// 个人资料、AI 模型、新闻存在 Worker 上，没填好 Worker 时点不了
    private var workerReady: Bool { !workerURL.isEmpty && hasToken }

    var body: some View {
        NavigationStack {
            Form {
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
                    row("新闻", icon: "newspaper", value: "兴趣 · 城市 · 汇率") {
                        NewsSettingsView()
                    }
                    .disabled(!workerReady)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            // 从 Worker、Gmail 页回来时更新右边的状态
            .onAppear(perform: refresh)
            .task(id: workerReady) {
                if workerReady { await config.loadIfNeeded() }
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

    private func refresh() {
        hasToken = !(AppSettings.workerToken ?? "").isEmpty
        gmailSignedIn = GoogleAuth.isSignedIn
        gmailEmail = GoogleAuth.tokens?.email
    }
}

// MARK: - Worker：地址、口令、测试连接

struct WorkerSettingsView: View {
    @AppStorage(SettingsKey.workerURL) private var workerURL = ""
    @State private var token = AppSettings.workerToken ?? ""
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle, checking, ok
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("https://dsa-worker.<你的账号>.workers.dev", text: $workerURL)
                    .urlInput()
                SecureField("访问口令 APP_TOKEN", text: $token)
                    .onChange(of: token) { _, newValue in AppSettings.workerToken = newValue }
                HStack {
                    Button("测试连接", action: check)
                        .disabled(workerURL.isEmpty || token.isEmpty || status == .checking)
                    Spacer()
                    statusLabel
                }
            } footer: {
                Text("你自己部署的 Cloudflare Worker，部署方法见 README。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Worker")
    }

    @ViewBuilder private var statusLabel: some View {
        switch status {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .ok: Label("已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
        case let .failed(message): Text(message).foregroundStyle(.red).font(.footnote).lineLimit(2)
        }
    }

    private func check() {
        status = .checking
        Task {
            do {
                try await DSAClient.fromSettings().health()
                status = .ok
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
