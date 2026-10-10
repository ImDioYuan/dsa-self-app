import AuthenticationServices
import SwiftData
import SwiftUI

struct SettingsView: View {
    let sync: TaskSyncService

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @AppStorage(SettingsKey.useCalendar) private var useCalendar = false
    @AppStorage(SettingsKey.useReminders) private var useReminders = false
    @AppStorage(SettingsKey.workerURL) private var workerURL = ""
    @AppStorage(SettingsKey.gmailForwardedLabel) private var forwardedLabel = ""
    @AppStorage(SettingsKey.gmailExtraQuery) private var gmailExtraQuery = ""
    @State private var icalFeeds = AppSettings.icalFeeds
    @State private var addingFeed = false
    @AppStorage(SettingsKey.lastSyncAt) private var lastSyncAt: Double = 0

    @AppStorage(SettingsKey.googleClientID) private var googleClientID = ""
    @Environment(\.webAuthenticationSession) private var webAuthSession

    @State private var token = AppSettings.workerToken ?? ""
    @State private var healthStatus: HealthStatus = .idle
    @State private var gmailSignedIn = GoogleAuth.isSignedIn
    @State private var gmailEmail = GoogleAuth.tokens?.email
    @State private var gmailError: String?
    @State private var signingIn = false
    @AppStorage(EmailChargeScanner.Key.enabled) private var emailChargesEnabled = true
    @State private var chargeScanner = EmailChargeScanner.shared

    /// 「上次检查：3 分钟前 · 新增 2 笔」
    private var chargeStatus: String? {
        let zh = Locale(identifier: "zh_CN")
        if let s = chargeScanner.lastSummary {
            if let error = s.error { return "检查失败：\(error)" }
            var text = "上次检查：\(s.date.formatted(.relative(presentation: .named).locale(zh)))"
            text += s.added.isEmpty ? " · 没有新的付款" : " · 新增 \(s.added.count) 笔（\(s.added.prefix(3).joined(separator: "、"))）"
            if s.duplicates > 0 { text += " · 跳过 \(s.duplicates) 笔已记过的" }
            return text
        }
        return EmailChargeScanner.lastRun.map { "上次检查：\($0.formatted(.relative(presentation: .named).locale(zh)))" }
    }

    enum HealthStatus: Equatable {
        case idle, checking, ok
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                ThemeSection()

                Section {
                    Toggle(isOn: $useCalendar) {
                        Label("苹果日历", systemImage: "calendar")
                    }
                    Toggle(isOn: $useReminders) {
                        Label("提醒事项", systemImage: "checklist")
                    }
                    ForEach(icalFeeds) { feed in
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(feed.name.isEmpty ? "订阅日历" : feed.name)
                                Text(feed.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        } icon: {
                            Image(systemName: TaskSource.ical.systemImage)
                        }
                    }
                    .onDelete { offsets in
                        icalFeeds.remove(atOffsets: offsets)
                        feedsChanged()
                    }
                    Button {
                        addingFeed = true
                    } label: {
                        Label("添加订阅日历", systemImage: "plus")
                    }
                } header: {
                    Text("日历")
                } footer: {
                    Text("第一次同步时系统会请求日历和提醒事项的权限；关掉后，它带进今日的任务会一起移除。\n订阅日历：粘贴 iCal 链接（https:// 或 webcal://），任务上显示你起的名字，左滑删除。")
                }
                .onChange(of: useCalendar) { _, on in sourceToggled(.calendar, on: on) }
                .onChange(of: useReminders) { _, on in sourceToggled(.reminders, on: on) }

                Section {
                    TextField("https://dsa-worker.<你的账号>.workers.dev", text: $workerURL)
                        .urlInput()
                    SecureField("访问口令 APP_TOKEN", text: $token)
                        .onChange(of: token) { _, newValue in AppSettings.workerToken = newValue }
                    HStack {
                        Button("测试连接", action: checkHealth)
                            .disabled(workerURL.isEmpty || token.isEmpty || healthStatus == .checking)
                        Spacer()
                        healthLabel
                    }
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        Label("AI 服务商和模型", systemImage: "cpu")
                    }
                    .disabled(workerURL.isEmpty || token.isEmpty)
                } header: {
                    Label("AI 服务（Cloudflare Worker）", systemImage: "sparkles")
                } footer: {
                    Text("Worker 是你自己部署的后端，保存 AI 的 API key，也保存下面的个人资料和新闻设置。")
                }

                Section {
                    NavigationLink {
                        ProfileSettingsView()
                    } label: {
                        Label("个人资料", systemImage: "person.crop.circle")
                    }
                    NavigationLink {
                        NewsSettingsView()
                    } label: {
                        Label("新闻", systemImage: "newspaper")
                    }
                } header: {
                    Text("个性化")
                } footer: {
                    Text("AI 挑新闻、写「对你的影响」、分析邮件时会参考你的资料。")
                }
                .disabled(workerURL.isEmpty || token.isEmpty)

                Section {
                    if gmailSignedIn {
                        LabeledContent("Gmail") { Text(gmailEmail ?? "已登录").foregroundStyle(.secondary) }
                        Button("重新分析最近 3 天的邮件") {
                            AnalyzedLog.gmail.reset()
                            Task { await sync.sync(context: context) }
                        }
                        .disabled(sync.isSyncing)
                        Button("退出 Gmail", role: .destructive) {
                            GoogleAuth.signOut()
                            gmailSignedIn = false
                        }
                    } else {
                        TextField("Google OAuth Client ID", text: $googleClientID, axis: .vertical)
                            .urlInput()
                        Button(action: signInGmail) {
                            HStack {
                                Label("登录 Gmail", systemImage: "envelope")
                                Spacer()
                                if signingIn { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(googleClientID.isEmpty || signingIn)
                    }
                    if let gmailError {
                        Text(gmailError).font(.footnote).foregroundStyle(.red)
                    }
                    TextField("转发邮件的 Gmail 标签（可选）", text: $forwardedLabel)
                        .urlInput()
                    TextField("特别关注的 Gmail 搜索（可选）", text: $gmailExtraQuery, axis: .vertical)
                        .urlInput()
                } header: {
                    Text("邮箱")
                } footer: {
                    Text("新邮件会发给你自己部署的 Worker，由 AI 判断要不要处理；分析过的邮件不会重复发送。需要先配置好上面的 AI 服务。\n转发标签：学校或公司邮箱（例如 Outlook）转发到 Gmail 后，用过滤器归到一个标签并跳过收件箱，在这里填标签名，DSA 会把它们标成 Outlook 来源。\n特别关注的搜索：Gmail 搜索语法，例如 company (interview OR offer)，命中的邮件即使被分到「推广」也会分析，配合 个人资料 → 特别关注 使用。")
                }

                Section {
                    NavigationLink {
                        QuickEntryGuide()
                    } label: {
                        Label("操作按钮 / Siri / Apple Pay 自动记账", systemImage: "bolt.circle")
                    }
                    Toggle(isOn: $emailChargesEnabled) {
                        Label("邮件自动记账", systemImage: "envelope.badge")
                    }
                    if emailChargesEnabled {
                        Button {
                            Task { await chargeScanner.run() }
                        } label: {
                            HStack {
                                Text("立即检查付款邮件")
                                Spacer()
                                if chargeScanner.isRunning { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(chargeScanner.isRunning || !gmailSignedIn)
                        if let status = chargeStatus {
                            Text(status).font(.footnote).foregroundStyle(chargeScanner.lastSummary?.error == nil ? Color.secondary : Color.red)
                        }
                    }
                } header: {
                    Text("记账快捷方式")
                } footer: {
                    Text(gmailSignedIn
                         ? "每天 8 点后第一次打开 DSA 时，自动检查 Gmail 里的付款收据（订阅续费、自动扣款、网购、外卖、退款等）并记进账本，和 Apple Pay 已记过的同一笔会自动跳过。"
                         : "邮件自动记账需要先在上面的「邮箱」里登录 Gmail。")
                }

                Section {
                    Button {
                        Task { await sync.sync(context: context) }
                    } label: {
                        HStack {
                            Text("立即同步")
                            Spacer()
                            if sync.isSyncing { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(sync.isSyncing)
                } footer: {
                    if lastSyncAt > 0 {
                        Text("上次同步：\(Date(timeIntervalSince1970: lastSyncAt).formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_CN"))))")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $addingFeed) {
            AddICalFeedSheet { feed in
                icalFeeds.append(feed)
                feedsChanged()
            }
        }
        .macSheetFrame(minWidth: 420, minHeight: 520)
        // 弹出页是单独一层，也要跟随主题和浅色 / 深色，切换时才能立刻变
        .themedTint()
    }

    @ViewBuilder private var healthLabel: some View {
        switch healthStatus {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .ok: Label("已连接", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.footnote)
        case let .failed(message): Text(message).foregroundStyle(.red).font(.footnote).lineLimit(2)
        }
    }

    /// 订阅日历改了：存下来、马上同步（删光了就移除它带进来的任务）
    private func feedsChanged() {
        AppSettings.icalFeeds = icalFeeds
        if icalFeeds.isEmpty {
            withAnimation { TaskSyncService.removeTasks(from: [.ical], in: context) }
        } else {
            Task { await sync.sync(context: context) }
        }
    }

    /// 关掉：马上移除这个数据源的任务；打开：马上同步一次，任务（和权限弹窗）立刻出来
    private func sourceToggled(_ source: TaskSource, on: Bool) {
        if on {
            Task { await sync.sync(context: context) }
        } else {
            withAnimation { TaskSyncService.removeTasks(from: [source], in: context) }
        }
    }

    private func signInGmail() {
        signingIn = true
        gmailError = nil
        Task {
            defer { signingIn = false }
            do {
                try await GoogleAuth.signIn(using: webAuthSession)
                gmailSignedIn = true
                gmailEmail = GoogleAuth.tokens?.email
            } catch GoogleAuth.AuthError.cancelled {
                // 用户自己关掉了登录页，不提示
            } catch {
                gmailError = error.localizedDescription
            }
        }
    }

    private func checkHealth() {
        healthStatus = .checking
        Task {
            do {
                try await DSAClient.fromSettings().health()
                healthStatus = .ok
            } catch {
                healthStatus = .failed(error.localizedDescription)
            }
        }
    }
}

/// 添加一个订阅日历：名字 + iCal 链接
private struct AddICalFeedSheet: View {
    let onAdd: (ICalFeed) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""

    private var feed: ICalFeed { ICalFeed(name: name.trimmingCharacters(in: .whitespaces), url: url.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字，例如 Moodle、课表", text: $name)
                    TextField("https:// 或 webcal:// 开头的链接", text: $url, axis: .vertical)
                        .urlInput()
                } footer: {
                    Text("""
                    各平台怎么拿链接：
                    · Moodle：Calendar → Import or export calendars → Export calendar，选 All courses 和 Recent and next 60 days → Get calendar URL
                    · Canvas：Calendar → 右下角 Calendar Feed
                    · Google 日历：日历的设置 → 「iCal 格式的私密地址」
                    · Outlook：设置 → 日历 → 共享日历 → 发布日历 → ICS 链接
                    """)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加订阅日历")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(feed)
                        dismiss()
                    }
                    .disabled(feed.downloadURL?.scheme?.hasPrefix("http") != true)
                }
            }
        }
        .macSheetFrame(minWidth: 420, minHeight: 360)
        .themedTint()
    }
}

private extension View {
    /// URL 输入框：关闭自动大写和自动纠错
    func urlInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
