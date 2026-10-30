import SwiftData
import SwiftUI

/// 一页一步完成必需的配置：部署 Worker → 连接 → AI 的 key → 个人资料。
/// 能在 app 里填的直接在这页填，做完打勾；最后一页总结，并列出接下来可以配置的。
/// 从 设置 → 用前配置 →「一步一步配置」打开（第一次打开 app 时新手引导会带到这里）。
/// 每一步推入一页，而不是在同一页里换内容：在原地换掉地址和口令两栏，系统会当成登录完成，弹「存储密码」
struct SetupWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var store = ConfigStore.shared
    @State private var status = SetupStatus()
    /// 第一页（部署）之后推入的页面
    @State private var path: [Page] = []
    @State private var started = false
    @State private var isSaving = false

    enum Page: Hashable {
        case step(SetupStep)
        case done
    }

    private static let steps = SetupStep.allCases.filter { $0.group == .required }
    private static let pages = steps.map(Page.step) + [.done]

    /// 必需的做完后推荐的几项
    private static var nextSteps: [SetupStep] {
        #if os(iOS)
        [.calendars, .gmail, .applePay, .interests]
        #else
        [.calendars, .gmail, .interests]
        #endif
    }

    var body: some View {
        NavigationStack(path: $path) {
            pageView(Self.pages[0])
                .navigationDestination(for: Page.self) { pageView($0) }
        }
        .onAppear {
            refresh()
            // 从第一个没做完的开始，前面做完的留在返回的路上
            guard !started else { return }
            started = true
            go(to: status.missingRequired.first.map(Page.step) ?? .done, animated: false)
        }
        // 连上 Worker、添加 key 后刷新状态
        .onChange(of: store.isLoading) { _, loading in if !loading { refresh() } }
        .onChange(of: store.saved) { _, _ in refresh() }
        .onDisappear {
            if store.hasChanges { Task { await store.save() } }
        }
        .macSheetFrame(minWidth: 520, minHeight: 680)
        .themedTint()
    }

    private func pageView(_ page: Page) -> some View {
        Form {
            header(page)
            switch page {
            case let .step(step): content(for: step)
            case .done: doneContent
            }
        }
        .formStyle(.grouped)
        .navigationTitle("基本配置")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("稍后") { dismiss() }
            }
        }
        // safeAreaBar：内容滚到按钮下面时自动变模糊，不会和按钮叠在一起
        .safeAreaBar(edge: .bottom) { bottomBar(page) }
    }

    // MARK: - 顶部：进度、标题、说明

    private func header(_ page: Page) -> some View {
        let index = Self.pages.firstIndex(of: page) ?? 0
        return Section {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { offset, step in
                        Capsule()
                            .fill(progressColor(offset == index, done: isDone(step)))
                            .frame(height: 4)
                    }
                }

                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: icon(page))
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .frame(width: 48, height: 48)
                        .background(.tint.opacity(0.12), in: .circle)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(page == .done ? "最后" : "第 \(index + 1) 步，共 \(Self.steps.count) 步")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(title(page)).font(.title2.bold())
                    }
                    Spacer(minLength: 0)
                    if case let .step(step) = page, isDone(step) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                            .accessibilityLabel("已完成")
                    }
                }

                Text(intro(page))
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
    }

    private func progressColor(_ current: Bool, done: Bool) -> Color {
        if current { return .accentColor }
        return done ? .accentColor.opacity(0.4) : .secondary.opacity(0.2)
    }

    private func title(_ page: Page) -> String {
        switch page {
        case let .step(step): step.title
        case .done: status.missingRequired.isEmpty ? "基本配置完成" : "还差 \(status.missingRequired.count) 步"
        }
    }

    private func icon(_ page: Page) -> String {
        switch page {
        case let .step(step): step.systemImage
        case .done: status.missingRequired.isEmpty ? "checkmark.seal" : "list.bullet.clipboard"
        }
    }

    private func intro(_ page: Page) -> String {
        switch page {
        case let .step(step):
            step.intro
        case .done:
            status.missingRequired.isEmpty
                ? "今日、记账、新闻都可以用了。下面这些是可选的，按需要配置。"
                : "没做完的随时可以在 设置 → 用前配置 里继续，每一步都有教程。"
        }
    }

    // MARK: - 每一步

    @ViewBuilder
    private func content(for step: SetupStep) -> some View {
        switch step {
        case .connectWorker:
            WorkerConnectionSection(footer: "地址是部署成功时显示的 https://dsa-worker.<子域名>.workers.dev，口令是上一步存进 APP_TOKEN 的那串。")
            if case let .warning(text) = status.state(step) {
                Section {
                    Label(store.error ?? text, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }

        case .aiKeys:
            if store.saved == nil {
                Section {
                    Text("先连上 Worker，这里才能显示哪几家已经配好了 key。")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(ProviderGuide.all) { provider in
                    NavigationLink {
                        ProviderGuideView(provider: provider)
                    } label: {
                        ProviderRow(provider: provider)
                    }
                }
            } header: {
                Text("选一家（或几家）")
            } footer: {
                Text("点进去看怎么拿到 key、怎么存进 Worker。有一家就能用。")
            }
            Section {
                Button {
                    Task { await store.load() }
                } label: {
                    HStack {
                        Text("加好了，检查一下")
                        Spacer()
                        if store.isLoading { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(store.isLoading || !status.workerFilled)
            } footer: {
                Text("哪个功能用哪家的哪个模型，以后可以在 设置 → AI 模型 里改。")
            }

        case .profile:
            if store.saved == nil {
                ConfigUnavailableSection()
            } else {
                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                ProfileSections(config: $store.draft)
            }

        default:
            // 部署 Worker：在 Mac 上做，这里只有教程
            GuideBlocksView(blocks: step.blocks)
        }
    }

    // MARK: - 最后一页

    @ViewBuilder
    private var doneContent: some View {
        Section("必需") {
            ForEach(Self.steps) { step in
                Button {
                    go(to: .step(step))
                } label: {
                    SetupStepRow(step: step, state: status.state(step))
                }
                .tint(.primary)
            }
        }

        Section {
            ForEach(Self.nextSteps) { step in
                NavigationLink {
                    SetupStepView(step: step)
                } label: {
                    SetupStepRow(step: step, state: status.state(step))
                }
            }
        } header: {
            Text("接下来可以")
        } footer: {
            Text("这些都在 设置 → 用前配置 里。")
        }
    }

    // MARK: - 底部按钮（返回用左上角的返回）

    private func bottomBar(_ page: Page) -> some View {
        HStack {
            Spacer()
            if isSkip(page) {
                Button("先跳过") { next(from: page) }
                    .buttonStyle(.glass)
            } else {
                Button {
                    next(from: page)
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(primaryTitle(page))
                    }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .controlSize(.large)
        .disabled(isSaving)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// 这一步还没做（部署没法检查，不算）
    private func isSkip(_ page: Page) -> Bool {
        guard case let .step(step) = page, step != .deployWorker else { return false }
        return !isDone(step)
    }

    private func primaryTitle(_ page: Page) -> String {
        switch page {
        case .step(.deployWorker): isDone(.deployWorker) ? "下一步" : "部署好了，下一步"
        case .step: "下一步"
        case .done: "开始使用"
        }
    }

    /// 个人资料按正在填的算（还没保存），其他的按实际状态
    private func isDone(_ step: SetupStep) -> Bool {
        if step == .profile, store.saved != nil {
            let config = store.draft
            return !config.name.trimmingCharacters(in: .whitespaces).isEmpty
                && !config.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return status.state(step).isDone
    }

    /// 离开个人资料页时先保存，保存失败就留在这页显示原因
    private func next(from page: Page) {
        let index = Self.pages.firstIndex(of: page) ?? 0
        guard index + 1 < Self.pages.count else {
            dismiss()
            return
        }
        let target = Self.pages[index + 1]
        guard page == .step(.profile), store.hasChanges else {
            go(to: target)
            return
        }
        isSaving = true
        Task {
            await store.save()
            isSaving = false
            refresh()
            if store.error == nil { go(to: target) }
        }
    }

    /// 前面的页都留在返回的路上：往后是推入，往前是返回
    private func go(to page: Page, animated: Bool = true) {
        let index = Self.pages.firstIndex(of: page) ?? 0
        let newPath = Array(Self.pages[1..<max(index + 1, 1)])
        if animated {
            path = newPath
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { path = newPath }
        }
    }

    private func refresh() {
        status = .current(context: context)
    }
}
