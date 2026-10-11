import EventKit
import SwiftData
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - 每一步的状态

enum StepState: Equatable {
    case done(String)
    case todo(String)
    case warning(String)
    /// 系统查不到做没做，只有教程
    case guide

    var isDone: Bool { if case .done = self { true } else { false } }
}

/// 现在配置到哪一步了。`GoogleAuth`、`AppSettings` 不会通知变化，页面出现时重新算一遍
@MainActor
struct SetupStatus {
    var workerFilled = false
    var config: UserConfig?
    var loading = false
    var error: String?
    var providers: [AIProvider] = []
    var calendar: EKAuthorizationStatus = .notDetermined
    var reminders: EKAuthorizationStatus = .notDetermined
    var applePayUsed = false
    var backgroundRefreshOn = true

    /// Worker 没有保存过兴趣时用的默认兴趣（worker/src/topics.ts 的 DEFAULT_TOPICS）
    private static let defaultTopics = ["conflict", "ai", "markets", "science"]

    static func current(context: ModelContext?) -> SetupStatus {
        let store = ConfigStore.shared
        var status = SetupStatus()
        status.workerFilled = (try? DSAClient.fromSettings()) != nil
        status.config = store.saved
        status.loading = store.isLoading
        status.error = store.error
        status.providers = store.providers
        status.calendar = EKEventStore.authorizationStatus(for: .event)
        status.reminders = EKEventStore.authorizationStatus(for: .reminder)
        if let context {
            let applePay = EntrySource.applePay.rawValue
            let count = try? context.fetchCount(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.sourceRaw == applePay }))
            status.applePayUsed = (count ?? 0) > 0
        }
        #if os(iOS)
        status.backgroundRefreshOn = UIApplication.shared.backgroundRefreshStatus == .available
        #endif
        return status
    }

    var connected: Bool { config != nil }

    func state(_ step: SetupStep) -> StepState {
        switch step {
        case .deployWorker:
            return connected ? .done("已连接") : .todo("")
        case .connectWorker:
            if connected { return .done("已连接") }
            if !workerFilled { return .todo("未填写") }
            return loading ? .todo("连接中…") : .warning("连不上")
        case .aiKeys:
            guard connected else { return .todo("") }
            let names = providers.filter(\.configured).map(\.name)
            return names.isEmpty ? .todo("还没有 key") : .done(names.joined(separator: "、"))
        case .profile:
            guard let config else { return .todo("") }
            let filled = !config.name.trimmingCharacters(in: .whitespaces).isEmpty
                && !config.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return filled ? .done(config.name) : .todo("未填")
        case .calendars:
            var on: [String] = []
            for (enabled, status, name) in [(AppSettings.useCalendar, calendar, "日历"), (AppSettings.useReminders, reminders, "提醒事项")] where enabled {
                if status == .denied || status == .restricted || status == .writeOnly { return .warning("\(name)没有权限") }
                on.append(name)
            }
            return on.isEmpty ? .todo("未打开") : .done(on.joined(separator: " · "))
        case .icalFeeds:
            let count = AppSettings.icalFeeds.count
            return count > 0 ? .done("\(count) 个") : .todo("")
        case .gmail:
            return GoogleAuth.isSignedIn ? .done(GoogleAuth.tokens?.email ?? "已登录") : .todo("未登录")
        case .forwarding:
            return AppSettings.gmailForwardedLabel.map { .done($0) } ?? .todo("")
        case .watchRules:
            guard let config else { return .todo("") }
            let count = config.watchRules.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            return count > 0 ? .done("\(count) 条") : .todo("")
        case .emailCharges:
            guard EmailChargeScanner.isEnabled else { return .todo("已关闭") }
            if !GoogleAuth.isSignedIn { return .todo("需要 Gmail") }
            return workerFilled ? .done("已打开") : .todo("需要 Worker")
        case .applePay:
            return applePayUsed ? .done("在用") : .guide
        case .quickEntry, .widgets, .csvImport:
            return .guide
        case .interests:
            guard let config else { return .todo("") }
            let topics = config.news.topics
            return topics == Self.defaultTopics ? .todo("默认的 \(topics.count) 个") : .done("\(topics.count) 个")
        case .newsBasics:
            guard let config else { return .todo("") }
            let count = config.news.places.count
            return count > 0 ? .done("\(count) 个城市") : .todo("")
        case .backgroundRefresh:
            return backgroundRefreshOn ? .done("已打开") : .warning("已关闭")
        }
    }

    var requiredSteps: [SetupStep] { SetupStep.allCases.filter { $0.group == .required } }

    /// 还没做完的必需步骤
    var missingRequired: [SetupStep] { requiredSteps.filter { !state($0).isDone } }

    /// 「今日」顶部要不要提醒：没填 Worker，或者连上了但还有必需的没做。填了但连不上（比如断网）时不打扰
    var needsAttention: Bool { !workerFilled || (connected && !missingRequired.isEmpty) }
}

// MARK: - 清单

/// 设置 → 用前配置：按步骤列出要做的配置，每一步显示做完没有，点进去是教程
struct SetupGuideView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var status = SetupStatus()
    @State private var store = ConfigStore.shared
    @State private var showingWizard = false

    var body: some View {
        Form {
            Section {
                let missing = status.missingRequired.count
                Label(
                    missing == 0 ? "必需的都配好了，可以开始用了" : "必需的还差 \(missing) 步",
                    systemImage: missing == 0 ? "checkmark.seal.fill" : "list.bullet.clipboard"
                )
                .foregroundStyle(missing == 0 ? Color.green : Color.primary)
                Button {
                    OnboardingTour.shared.finish()
                    showingWizard = true
                } label: {
                    Text("一步一步配置").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tourTarget(.wizardButton)
            } footer: {
                Text("按顺序做完「必需」的几步就能用；其他按需要配置。")
            }

            ForEach(SetupStep.Group.allCases, id: \.self) { group in
                Section(group.title) {
                    ForEach(SetupStep.visible.filter { $0.group == group }) { step in
                        NavigationLink {
                            SetupStepView(step: step)
                        } label: {
                            SetupStepRow(step: step, state: status.state(step))
                        }
                    }
                }
            }

            Section {
                Button("重新看新手引导") {
                    dismiss()
                    OnboardingTour.shared.restart()
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("用前配置")
        .onAppear {
            refresh()
            OnboardingTour.shared.guideAppeared()
        }
        .sheet(isPresented: $showingWizard, onDismiss: refresh) {
            SetupWizardView()
        }
        .task {
            guard status.workerFilled else { return }
            await store.loadIfNeeded()
            refresh()
        }
        .refreshable {
            await store.load()
            refresh()
        }
    }

    private func refresh() {
        status = .current(context: context)
    }
}

struct SetupStepRow: View {
    let step: SetupStep
    let state: StepState

    var body: some View {
        LabeledContent {
            StepStateView(state: state)
        } label: {
            Label(step.title, systemImage: step.systemImage)
        }
    }
}

/// 右边的状态：文字 + ✅ / ○ / ⚠️
struct StepStateView: View {
    let state: StepState

    var body: some View {
        HStack(spacing: 6) {
            switch state {
            case let .done(text):
                Text(text).lineLimit(1)
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case let .todo(text):
                Text(text).lineLimit(1)
                Image(systemName: "circle").foregroundStyle(.tertiary)
            case let .warning(text):
                Text(text).lineLimit(1)
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .guide:
                EmptyView()
            }
        }
        .font(.subheadline)
    }
}

// MARK: - 一步的教程

struct SetupStepView: View {
    let step: SetupStep
    /// 从对应的设置页点进来时不再显示「去设置」
    var showsSettingsLink = true

    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var status = SetupStatus()

    var body: some View {
        Form {
            Section {
                Text(step.intro)
                if status.state(step) != .guide {
                    LabeledContent("状态") { StepStateView(state: status.state(step)) }
                }
            }

            GuideBlocksView(blocks: step.blocks)

            if showsSettingsLink {
                settingsSection
            }
        }
        .formStyle(.grouped)
        .navigationTitle(step.title)
        .onAppear { status = .current(context: context) }
    }

    @ViewBuilder private var settingsSection: some View {
        switch step {
        case .deployWorker, .connectWorker:
            Section { NavigationLink("去 设置 → Worker") { WorkerSettingsView() } }
        case .aiKeys:
            Section { NavigationLink("去 设置 → AI 模型") { AISettingsView() } }
        case .profile:
            Section { NavigationLink("去 设置 → 个人资料") { ProfileSettingsView() } }
        case .calendars, .icalFeeds, .watchRules:
            Section { NavigationLink("去 设置 → 今日") { TodaySettingsView(sync: .shared) } }
        case .gmail, .forwarding:
            Section { NavigationLink("去 设置 → Gmail") { GmailSettingsView(sync: .shared) } }
        case .emailCharges:
            Section { NavigationLink("去 设置 → 记账") { LedgerSettingsView() } }
        case .interests:
            Section { NavigationLink("去 我的兴趣") { InterestsView() } }
        case .newsBasics:
            Section { NavigationLink("去 设置 → 新闻") { NewsSettingsView() } }
        case .csvImport:
            Section { Button("打开记账页") { AppRouter.shared.tab = .ledger } }
        #if os(iOS)
        case .applePay:
            Section { Button("打开快捷指令") { openURL(URL(string: "shortcuts://")!) } }
        case .backgroundRefresh:
            Section { Button("打开 DSA 的系统设置") { openURL(URL(string: UIApplication.openSettingsURLString)!) } }
        #endif
        default:
            EmptyView()
        }
    }
}

// MARK: - 教程内容的显示

/// 按小标题分成几组，每组里的步骤从 1 开始编号
struct GuideBlocksView: View {
    let blocks: [GuideBlock]

    private struct Group {
        var heading: String?
        var rows: [(number: Int?, block: GuideBlock)] = []
    }

    private var groups: [Group] {
        var groups: [Group] = []
        var current = Group()
        var number = 0
        for block in blocks {
            switch block {
            case let .heading(title):
                if !current.rows.isEmpty || current.heading != nil { groups.append(current) }
                current = Group(heading: title)
                number = 0
            case .step:
                number += 1
                current.rows.append((number, block))
            default:
                current.rows.append((nil, block))
            }
        }
        if !current.rows.isEmpty || current.heading != nil { groups.append(current) }
        return groups
    }

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            Section {
                ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                    GuideBlockRow(block: row.block, number: row.number)
                }
            } header: {
                if let heading = group.heading { Text(heading) }
            }
        }
    }
}

private struct GuideBlockRow: View {
    let block: GuideBlock
    let number: Int?

    var body: some View {
        switch block {
        case let .step(text):
            NumberedStep(number: number ?? 1, text: text)
        case let .command(command):
            CopyableRow(value: command, monospaced: true)
        case let .link(title, url):
            if let url = URL(string: url) {
                Link(destination: url) {
                    Label(title, systemImage: "safari")
                }
            }
        case let .text(text):
            Text(text)
        case let .note(text):
            Text(text).font(.footnote).foregroundStyle(.secondary)
        case .bundleID:
            CopyableRow(label: "Bundle ID", value: Bundle.main.bundleIdentifier ?? "", monospaced: true)
        case .providers:
            ForEach(ProviderGuide.all) { provider in
                NavigationLink {
                    ProviderGuideView(provider: provider)
                } label: {
                    ProviderRow(provider: provider)
                }
            }
        case .heading:
            EmptyView()
        }
    }
}

struct NumberedStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: .circle)
            Text(text)
        }
    }
}

/// 一行可以复制的命令或文字
struct CopyableRow: View {
    var label: String?
    let value: String
    var monospaced = false

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            if let label {
                Text(label)
                Spacer(minLength: 8)
            }
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .textSelection(.enabled)
            if label == nil { Spacer(minLength: 8) }
            Button {
                copyToPasteboard(value)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "已复制" : "复制")
        }
    }
}

func copyToPasteboard(_ text: String) {
    #if canImport(UIKit)
    UIPasteboard.general.string = text
    #else
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #endif
}

// MARK: - AI 服务商

struct ProviderRow: View {
    let provider: ProviderGuide
    @State private var store = ConfigStore.shared

    var body: some View {
        LabeledContent {
            if store.providers.first(where: { $0.id == provider.id })?.configured == true {
                StepStateView(state: .done("已配置"))
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name)
                Text(ProviderGuideView.badges(for: provider, store: store).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ProviderGuideView: View {
    let provider: ProviderGuide
    @State private var store = ConfigStore.shared

    /// 能力标签：联网搜索、看图从 Worker 读（没连上时不显示），再加上教程里写的
    static func badges(for provider: ProviderGuide, store: ConfigStore) -> [String] {
        var badges: [String] = []
        if let info = store.providers.first(where: { $0.id == provider.id }) {
            if info.webSearch { badges.append("联网搜索") }
            let taskModel = info.defaults["tasks"]
            if info.models.first(where: { $0.id == taskModel })?.vision ?? true { badges.append("能看图") }
        }
        return badges + provider.extras
    }

    private var configured: Bool {
        store.providers.first(where: { $0.id == provider.id })?.configured == true
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("状态") {
                    if store.saved == nil {
                        Text("连上 Worker 后显示").foregroundStyle(.secondary)
                    } else {
                        Text(configured ? "已配置" : "未配置").foregroundStyle(configured ? .green : .secondary)
                    }
                }
                Text(provider.notes)
                if !provider.tested {
                    Text("按官方文档接入，还没有用真实账号完整测过；遇到问题可以先换成 Claude。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("拿到 key") {
                ForEach(Array(provider.steps.enumerated()), id: \.offset) { index, step in
                    NumberedStep(number: index + 1, text: step)
                }
                if let url = URL(string: provider.url) {
                    Link(destination: url) { Label(provider.site, systemImage: "safari") }
                }
            }

            Section {
                CopyableRow(value: "npx wrangler secret put \(provider.secret)", monospaced: true)
            } header: {
                Text("存进 Worker")
            } footer: {
                Text("在 worker 文件夹里运行，粘贴 key 后回车。马上生效，不用重新部署。")
            }

            Section {
                NavigationLink("去 设置 → AI 模型") { AISettingsView() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(provider.name)
    }
}

// MARK: - 「今日」顶部的提醒

/// 必需的几步没做完时显示在「今日」最上面，做完自动消失
struct SetupReminderCard: View {
    let missing: [SetupStep]
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("还差 \(missing.count) 步就能用", systemImage: "list.bullet.clipboard")
                .font(.headline)
            Text(missing.map(\.title).joined(separator: "、"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("去配置", action: onOpen)
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 24, padding: 18)
    }
}
