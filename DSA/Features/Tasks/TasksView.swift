import SwiftData
import SwiftUI

/// 「今日」页：顶部四象限（重要程度 × 离截止多久），下面按象限列出要处理的事
struct TasksView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \TaskItem.createdAt, order: .reverse) private var items: [TaskItem]

    @State private var sync = TaskSyncService.shared
    @State private var setup = SetupStatus()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAdd = false
    @State private var showDone = false
    @State private var expandedIDs: Set<PersistentIdentifier> = []
    /// 从四象限点过来的那张卡片闪一下
    @State private var highlightedID: PersistentIdentifier?
    /// 正在显示的放大四象限
    @State private var presentedMatrix: MatrixPresentation?
    /// 四象限卡片在屏幕上的位置：放大时从这里出来，收起时回到这里
    @State private var matrixCardFrame: CGRect = .zero
    @AppStorage(SettingsKey.urgentHorizonHours) private var horizonHours = UrgencyScale.defaultHorizonHours

    /// 同一象限里先按截止时间排（没有截止时间的放最后），同一时间重要的在前
    private func section(_ open: [TaskGroup], _ quadrant: Quadrant, scale: UrgencyScale, now: Date) -> [TaskGroup] {
        open
            .filter { $0.main.quadrant(scale, now: now) == quadrant }
            .sorted {
                ($0.main.due ?? .distantFuture, -$0.main.importanceRaw) < ($1.main.due ?? .distantFuture, -$1.main.importanceRaw)
            }
    }

    var body: some View {
        // 象限随时间变化（离截止越来越近就变紧急），每分钟重新算一次
        TimelineView(.everyMinute) { timeline in
            content(now: timeline.date)
        }
    }

    private func content(now: Date) -> some View {
        let scale = UrgencyScale(horizonHours: Double(horizonHours))
        // 同一件事被几个数据源重复带进来时（Moodle 和 Outlook 都提醒同一个作业、同一个日程在两个日历里）只显示一条
        let groups = TaskItem.grouped(items).map(TaskGroup.init(items:))
        let open = groups.filter { !$0.main.isDone }
        let done = groups.filter(\.main.isDone).sorted { $0.main.updatedAt > $1.main.updatedAt }.prefix(30)
        let matrixTasks = open.map { group in
            let item = group.main
            return MatrixTask(id: group.id, title: item.title, due: item.due, importance: item.importance,
                              quadrant: item.quadrant(scale, now: now), x: scale.x(for: item.due, now: now))
        }

        return NavigationStack {
            // 用 ScrollView 而不是 List：List 的行高变化不跟 SwiftUI 动画同步，
            // 展开 / 收起时下面的卡片会瞬间跳位、和正在收起的内容叠在一起
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        TodayHeader(openItems: open.map(\.main), doNow: matrixTasks.filter { $0.quadrant == .doNow }.count,
                                    isSyncing: sync.isSyncing)

                        if setup.needsAttention {
                            SetupReminderCard(missing: setup.missingRequired) { AppRouter.shared.openSetupGuide() }
                        }

                        if !sync.errors.isEmpty {
                            SyncErrorCard(errors: sync.errors) {
                                withAnimation { sync.dismissErrors() }
                            }
                        }

                        if open.isEmpty {
                            EmptyTasksCard(onOpenSettings: { AppRouter.shared.openSetupGuide() })
                        } else {
                            QuadrantMatrixCard(
                                tasks: matrixTasks, scale: scale, horizonHours: $horizonHours,
                                onSelect: { jump(to: $0, in: open, proxy: proxy) },
                                onOpen: { focus in
                                    withoutAnimation { presentedMatrix = MatrixPresentation(focus: focus, sourceFrame: matrixCardFrame) }
                                }
                            )
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { matrixCardFrame = $0 }
                            // 放大时卡片「浮起来」，原位置先空着，收回后再出现
                            .opacity(presentedMatrix == nil ? 1 : 0)
                        }

                        ForEach(Quadrant.allCases) { quadrant in
                            let rows = section(open, quadrant, scale: scale, now: now)
                            if !rows.isEmpty {
                                QuadrantTitle(quadrant: quadrant, count: rows.count)
                                    .padding(.top, 12)
                                    .padding(.horizontal, 4)
                                ForEach(rows) { group in
                                    row(group, tint: quadrant.tint, urgent: quadrant.isUrgent, now: now)
                                }
                            }
                        }

                        if !done.isEmpty {
                            Button {
                                withAnimation(.smooth(duration: 0.3)) { showDone.toggle() }
                            } label: {
                                HStack {
                                    SectionTitle(text: "已完成", count: done.count, tint: .green)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .rotationEffect(.degrees(showDone ? 90 : 0))
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 12)
                            .padding(.horizontal, 4)

                            if showDone {
                                ForEach(done) { group in row(group, tint: .secondary, urgent: false, now: now) }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                // iOS 用透明的 fullScreenCover 才能盖住导航栏和底部标签栏；动画由放大层自己做，系统的上滑动画关掉
                #if os(iOS)
                .fullScreenCover(item: $presentedMatrix) { presentation in
                    matrixOverlay(presentation, tasks: matrixTasks, scale: scale, open: open, proxy: proxy)
                        .presentationBackground(.clear)
                }
                #else
                .overlay {
                    if let presentation = presentedMatrix {
                        matrixOverlay(presentation, tasks: matrixTasks, scale: scale, open: open, proxy: proxy)
                    }
                }
                #endif
            }
            .background { AmbientBackground() }
            .navigationTitle("今日")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        Task { await sync.sync(context: context) }
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .disabled(sync.isSyncing)

                    Button { showAdd = true } label: {
                        Label("添加", systemImage: "plus")
                    }
                }
            }
            .refreshable { await sync.sync(context: context) }
            .task { await sync.syncIfStale(context: context) }
            // 回到这一页或回到前台时，看看必需的配置做完没有
            .task(id: scenePhase) { await refreshSetup() }
            .onAppear { setup = .current(context: context) }
            .sheet(isPresented: $showAdd) { AddTaskSheet() }
        }
    }

    private func refreshSetup() async {
        setup = .current(context: context)
        guard setup.workerFilled else { return }
        await ConfigStore.shared.loadIfNeeded()
        setup = .current(context: context)
    }

    /// 点气泡打开时带上气泡的位置。放在 item 里一起传：先改一个 @State 再用 isPresented 弹出，
    /// 弹出层拿到的还是旧值
    struct MatrixPresentation: Identifiable {
        let id = UUID()
        var focus: CGPoint?
        var sourceFrame: CGRect
    }

    private func matrixOverlay(
        _ presentation: MatrixPresentation, tasks: [MatrixTask], scale: UrgencyScale,
        open: [TaskGroup], proxy: ScrollViewProxy
    ) -> some View {
        QuadrantMatrixOverlay(
            tasks: tasks, scale: scale, horizonHours: $horizonHours,
            focus: presentation.focus, sourceFrame: presentation.sourceFrame,
            onClose: { selected in
                // 卡片已经收回原位，直接拿掉弹出层（不要系统的下滑动画）
                withoutAnimation { presentedMatrix = nil }
                if let selected { jump(to: selected, in: open, proxy: proxy) }
            }
        )
    }

    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// 四象限里点了一个任务：滚到下面它的卡片，展开详情，闪一下
    private func jump(to id: PersistentIdentifier, in open: [TaskGroup], proxy: ScrollViewProxy) {
        guard let item = open.first(where: { $0.id == id })?.main else { return }
        withAnimation(.smooth(duration: 0.45)) {
            if !item.detail.isEmpty || item.url != nil { expandedIDs.insert(id) }
            highlightedID = id
            proxy.scrollTo(id, anchor: .center)
        }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if highlightedID == id {
                withAnimation(.easeOut(duration: 0.5)) { highlightedID = nil }
            }
        }
    }

    private func row(_ group: TaskGroup, tint: Color, urgent: Bool, now: Date) -> some View {
        let item = group.main
        return TaskRow(
            item: item,
            alsoFrom: group.otherSources,
            tint: tint,
            showsCountdown: urgent,
            now: now,
            isExpanded: expandedIDs.contains(item.persistentModelID),
            isHighlighted: highlightedID == group.id,
            onToggle: { toggle(group) },
            onExpand: { toggleExpanded(item) }
        )
            .id(group.id)
            #if os(iOS)
            .contentShape(.contextMenuPreview, .rect(cornerRadius: 20))
            #endif
            .contextMenu {
                Button { toggle(group) } label: {
                    Label(item.isDone ? "标为未完成" : "完成", systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark")
                }
                if let url = item.url {
                    Link(destination: url) { Label("打开原文", systemImage: "arrow.up.right.square") }
                }
                // 改了以后同步不会再覆盖；藏起来的重复几条一起改，换哪条显示都一样
                Picker("重要程度", selection: Binding(get: { item.importance }, set: { value in
                    withAnimation(.snappy) {
                        for copy in group.items { copy.importance = value }
                    }
                })) {
                    ForEach(Importance.allCases.reversed(), id: \.self) { Text($0.displayName).tag($0) }
                }
                Button(role: .destructive) { delete(group) } label: {
                    Label("删除", systemImage: "trash")
                }
            }
    }

    /// 展开 / 收起：整页一起做动画，下面的卡片跟着平滑移动
    private func toggleExpanded(_ item: TaskItem) {
        guard !item.detail.isEmpty || item.url != nil else { return }
        let id = item.persistentModelID
        withAnimation(.smooth(duration: 0.3)) {
            if expandedIDs.contains(id) {
                expandedIDs.remove(id)
            } else {
                expandedIDs.insert(id)
            }
        }
    }

    /// 藏起来的那几条也要一起完成 / 删除，不然会冒出来
    private func toggle(_ group: TaskGroup) {
        let done = !group.main.isDone
        withAnimation(.snappy) {
            for item in group.items {
                item.isDone = done
                item.updatedAt = .now
            }
        }
    }

    private func delete(_ group: TaskGroup) {
        withAnimation {
            for item in group.items { context.delete(item) }
        }
    }
}

/// 同一件事的几条任务。只显示 main，其余的来源标在它旁边
private struct TaskGroup: Identifiable {
    let items: [TaskItem]

    var main: TaskItem { items[0] }
    var id: PersistentIdentifier { main.persistentModelID }

    /// 其他几条的来源名字（去掉和 main 一样的）
    var otherSources: [String] {
        var seen: Set<String> = [main.sourceName]
        return items.map(\.sourceName).filter { seen.insert($0).inserted }
    }
}

// MARK: - 行

struct TaskRow: View {
    let item: TaskItem
    /// 同一件事还从哪些数据源来过（重复的那几条没显示）
    var alsoFrom: [String] = []
    /// 所在象限的颜色
    var tint: Color = .secondary
    /// 紧急的显示倒计时
    var showsCountdown = false
    var now: Date = .now
    var isExpanded: Bool
    var isHighlighted = false
    var onToggle: () -> Void
    var onExpand: () -> Void

    @Environment(\.openURL) private var openURL

    private var hasDetails: Bool { !item.detail.isEmpty || item.url != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isDone ? Color.green : tint)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .strikethrough(item.isDone)
                    .foregroundStyle(item.isDone ? .secondary : .primary)
                    .lineLimit(isExpanded ? nil : 2)

                HStack(spacing: 8) {
                    Label(([item.sourceName] + alsoFrom).joined(separator: " · "), systemImage: item.source.systemImage)
                        .font(.caption)
                        .foregroundStyle(item.source.tint)
                    Pill(text: item.kind.displayName, tint: tint)
                    if let due = item.due {
                        Text(DueText.string(for: due, now: now))
                            .font(.caption)
                            .foregroundStyle(due < now && !item.isDone ? Color.red : Color.secondary)
                        if showsCountdown && due >= now && !item.isDone {
                            Text(Countdown.string(to: due, now: now))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(tint.gradient, in: .capsule)
                        }
                    }
                }
                .padding(.top, 6)

                // 详情一直在视图里，收起时高度为 0 并裁掉：高度和卡片一起连续变化，
                // 不会出现「卡片已经缩回去、文字还在淡出」压到下一条上的卡顿
                if hasDetails {
                    details
                        .frame(height: isExpanded ? nil : 0, alignment: .top)
                        .clipped()
                        .opacity(isExpanded ? 1 : 0)
                        .accessibilityHidden(!isExpanded)
                }
            }
            Spacer(minLength: 0)
        }
        .glassCard(cornerRadius: 20, padding: 14)
        // 左边一条象限颜色，扫一眼就知道是哪一类
        .overlay(alignment: .leading) {
            if !item.isDone {
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: 3.5)
                    .padding(.vertical, 14)
                    .padding(.leading, 3)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(tint, lineWidth: 2.5)
                .opacity(isHighlighted ? 1 : 0)
        }
        .scaleEffect(isHighlighted ? 1.02 : 1)
        .contentShape(.rect)
        .onTapGesture(perform: onExpand)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = item.url {
                // 单独的按钮（borderless）：自己接收点击，不会被整张卡片的「展开 / 收起」吃掉
                Button {
                    openURL(url)
                } label: {
                    Label("打开原文", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 顶部卡片 & 状态卡片

private struct TodayHeader: View {
    let openItems: [TaskItem]
    /// 重要又紧急的
    let doNow: Int
    let isSyncing: Bool

    private var dueToday: Int {
        openItems.filter { $0.due.map(Calendar.current.isDateInToday) ?? false }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Date.now, format: .dateTime.month().day().weekday(.wide).locale(Locale(identifier: "zh_CN")))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if isSyncing { ProgressView().controlSize(.small) }
            }
            HStack(spacing: 22) {
                Stat(value: doNow, label: Quadrant.doNow.displayName, tint: Quadrant.doNow.tint)
                Stat(value: dueToday, label: "今天截止", tint: .orange)
                Stat(value: openItems.count, label: "待处理", tint: .accentColor)
            }
        }
        .glassCard(cornerRadius: 26, padding: 18)
    }

    private struct Stat: View {
        let value: Int
        let label: String
        let tint: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(value > 0 ? tint : .secondary)
                    .contentTransition(.numericText())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SyncErrorCard: View {
    let errors: [TaskSource: String]
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("部分数据源同步失败", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }
            ForEach(errors.sorted(by: { $0.key.rawValue < $1.key.rawValue }), id: \.key) { source, message in
                Text("\(source.displayName)：\(message)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .glassCard(cornerRadius: 20, padding: 14)
    }
}

private struct EmptyTasksCard: View {
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text("暂时没有要处理的事")
                .font(.headline)
            Text("在 设置 → 用前配置 里打开日历、连接 Gmail 或添加订阅日历，要做的事会整理到这里。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("打开用前配置", action: onOpenSettings)
                .buttonStyle(.glass)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 24, padding: 22)
    }
}

private struct SectionTitle: View {
    let text: String
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text).font(.subheadline.weight(.semibold))
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
        }
        .textCase(nil)
        .foregroundStyle(.primary)
    }
}

/// 象限标题：颜色点 + 名字 + 两个轴，例如「● 马上做 3  重要 · 紧急」
private struct QuadrantTitle: View {
    let quadrant: Quadrant
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(quadrant.tint).frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(quadrant.displayName).font(.subheadline.weight(.semibold))
            Text("\(count)").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(quadrant.axes).font(.caption).foregroundStyle(quadrant.tint)
        }
    }
}

// MARK: - 工具

extension View {
    /// 去掉 List 默认的行背景和分隔线，让玻璃卡片直接浮在渐变上
    func cleanRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
    }
}

/// 截止时间的人话写法：今天 15:00 / 明天 09:30 / 周五 17:00 / 10月12日
enum DueText {
    static func string(for date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        let time = timeFormatter.string(from: date)
        let prefix = date < now ? "已过期 · " : ""

        if cal.isDateInToday(date) { return prefix + "今天 \(time)" }
        if cal.isDateInTomorrow(date) { return prefix + "明天 \(time)" }
        if cal.isDateInYesterday(date) { return prefix + "昨天 \(time)" }

        let days = cal.dateComponents([.day], from: cal.startOfDay(for: now), to: cal.startOfDay(for: date)).day ?? 0
        let zh = Locale(identifier: "zh_CN")
        if (0..<7).contains(days) {
            return date.formatted(.dateTime.weekday(.abbreviated).locale(zh)) + " \(time)"
        }
        return prefix + date.formatted(.dateTime.month().day().locale(zh))
    }

    /// 固定 24 小时制（中文格式默认是 12 小时制，省掉上午/下午就会显示错）
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}

#Preview {
    RootView()
        .modelContainer(PreviewData.container)
}



