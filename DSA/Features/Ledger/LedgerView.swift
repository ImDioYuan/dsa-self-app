import Charts
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// 「记账」页：收支汇总、预算、分类占比、趋势、流水
struct LedgerView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LedgerEntry.date, order: .reverse) private var entries: [LedgerEntry]
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    @AppStorage(LedgerSettingsKey.displayCurrency) private var displayCurrencyRaw = Currency.base.rawValue
    @AppStorage(LedgerSettingsKey.monthlyBudget) private var monthlyBudget: Double = 0

    @State private var rates = ExchangeRates.shared
    @State private var router = AppRouter.shared
    @State private var chargeScanner = EmailChargeScanner.shared
    @State private var dismissedChargeSummary: Date?
    @State private var mode: PeriodMode = .month
    @State private var anchor = Date.now
    @State private var editor: EditorTarget?
    @State private var showCategories = false
    @State private var showDocumentCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var scanning = false
    @State private var scanError: String?
    @State private var failedImage: Data?
    @State private var showCSVImporter = false
    @State private var csvSession: CSVImportSession?
    @State private var csvError: String?
    @State private var toast: String?

    enum PeriodMode: String, CaseIterable, Identifiable {
        case month = "月", year = "年"
        var id: String { rawValue }
    }

    private var display: Currency { Currency(rawValue: displayCurrencyRaw) ?? .base }

    private var interval: DateInterval {
        mode == .month ? LedgerStats.monthInterval(containing: anchor) : LedgerStats.yearInterval(containing: anchor)
    }

    private var periodEntries: [LedgerEntry] {
        let range = interval
        return entries.filter { $0.date >= range.start && $0.date < range.end }
    }

    private var values: [EntryValue] { periodEntries.map(\.value) }

    var body: some View {
        NavigationStack {
            List {
                PeriodHeader(mode: $mode, anchor: $anchor)
                    .cleanRow()

                if let summary = chargeScanner.lastSummary, !summary.added.isEmpty, dismissedChargeSummary != summary.date {
                    EmailChargeBanner(summary: summary) { withAnimation { dismissedChargeSummary = summary.date } }
                        .cleanRow()
                }

                SummaryCard(totals: LedgerStats.totals(values), format: show)
                    .cleanRow()

                if mode == .month, monthlyBudget > 0 || categories.contains(where: { $0.monthlyBudget != nil }) {
                    BudgetCard(
                        spent: LedgerStats.totals(values).expense,
                        budget: monthlyBudget,
                        month: interval,
                        categoryBudgets: categoryBudgetRows,
                        format: show
                    )
                    .cleanRow()
                }

                if periodEntries.isEmpty {
                    emptyCard.cleanRow()
                } else {
                    BreakdownCard(values: values, category: category(for:), convert: convert, format: show)
                        .cleanRow()
                    TrendCard(mode: mode, values: entries.map(\.value), interval: interval, convert: convert)
                        .cleanRow()
                }

                if mode == .month {
                    ForEach(dayGroups, id: \.day) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                EntryRow(entry: entry, category: category(for: entry.categoryID), display: display, format: show)
                                    .cleanRow()
                                    .contentShape(.rect)
                                    .onTapGesture { editor = .edit(entry) }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            withAnimation { context.delete(entry) }
                                        } label: { Label("删除", systemImage: "trash") }
                                    }
                            }
                        } header: {
                            DayHeader(day: group.day, expense: group.expense, format: show)
                        }
                    }
                } else {
                    Section {
                        ForEach(LedgerStats.monthly(values, year: interval).reversed(), id: \.month) { row in
                            MonthRow(month: row.month, totals: row.totals, format: show)
                                .cleanRow()
                                .contentShape(.rect)
                                .onTapGesture {
                                    withAnimation { anchor = row.month; mode = .month }
                                }
                        }
                    } header: {
                        Text("每月明细").font(.subheadline.weight(.semibold)).textCase(nil).foregroundStyle(.primary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background { AmbientBackground() }
            .navigationTitle("记账")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("显示货币", selection: $displayCurrencyRaw) {
                            ForEach(Currency.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                    } label: {
                        Label("显示货币", systemImage: "dollarsign.arrow.circlepath")
                    }

                    Button { showCategories = true } label: {
                        Label("分类与预算", systemImage: "slider.horizontal.3")
                    }

                    Menu {
                        #if os(iOS)
                        if DocumentCamera.isSupported {
                            Button { showDocumentCamera = true } label: { Label("拍小票", systemImage: "camera") }
                        }
                        #endif
                        // PhotosPicker 直接放在 Menu 里会随菜单一起消失，所以用按钮 + .photosPicker 弹出
                        Button { showPhotoPicker = true } label: {
                            Label("从相册选择", systemImage: "photo")
                        }
                        Button { showCSVImporter = true } label: {
                            Label("导入 CSV", systemImage: "tablecells")
                        }
                    } label: {
                        Label("识别账单", systemImage: "doc.text.viewfinder")
                    }
                    .disabled(scanning)

                    Button { editor = .new } label: {
                        Label("记一笔", systemImage: "plus")
                    }
                }
            }
            .task {
                DefaultCategories.ensureSeeded(in: context)
                await rates.refreshIfNeeded()
            }
            // 快捷指令 / 控制中心 / 相机按钮带进来的「记一笔」
            .onAppear(perform: consumePendingDraft)
            .onChange(of: router.pendingDraft) { _, _ in consumePendingDraft() }
            .onChange(of: router.pendingReceipt) { _, _ in consumePendingDraft() }
            // 显示货币、预算变了，小组件也要跟着变
            .onChange(of: displayCurrencyRaw) { _, _ in LedgerSnapshotWriter.update(context: context) }
            .onChange(of: monthlyBudget) { _, _ in LedgerSnapshotWriter.update(context: context) }
            .sheet(item: $editor) { target in
                switch target {
                case .new: EntryEditor(entry: nil)
                case let .edit(entry): EntryEditor(entry: entry)
                case let .draft(draft): EntryEditor(entry: nil, draft: draft)
                }
            }
            .sheet(isPresented: $showCategories) { CategoryManager() }
            #if os(iOS)
            .fullScreenCover(isPresented: $showDocumentCamera) {
                DocumentCamera { data in scanReceipt(data) }.ignoresSafeArea()
            }
            #endif
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) { scanReceipt(data) }
                }
            }
            .fileImporter(isPresented: $showCSVImporter, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
                openCSV(result)
            }
            .sheet(item: $csvSession) { session in
                CSVImportSheet(session: session) { count, latest in
                    guard count > 0 else { return }
                    withAnimation(.snappy) {
                        // 跳到导入的那个月，马上能看到
                        if let latest { mode = .month; anchor = latest }
                        toast = "已导入 \(count) 笔"
                    }
                }
            }
            .overlay(alignment: .top) {
                if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: .capsule)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task(id: toast) {
                            try? await Task.sleep(for: .seconds(2.5))
                            withAnimation { self.toast = nil }
                        }
                }
            }
            .overlay {
                if scanning {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("正在识别小票…").font(.subheadline)
                    }
                    .padding(28)
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
                }
            }
            .alert("无法导入 CSV", isPresented: Binding(get: { csvError != nil }, set: { if !$0 { csvError = nil } })) {
                Button("好", role: .cancel) {}
            } message: {
                Text(csvError ?? "")
            }
            .alert("识别失败", isPresented: Binding(get: { scanError != nil }, set: { if !$0 { scanError = nil } })) {
                Button("手动记一笔") { editor = .draft(EntryDraft(source: .receipt, receiptImage: failedImage)) }
                Button("取消", role: .cancel) {}
            } message: {
                Text(scanError ?? "")
            }
        }
    }

    private func consumePendingDraft() {
        if let image = router.pendingReceipt {
            router.pendingReceipt = nil
            scanReceipt(image)
        }
        if let draft = router.pendingDraft {
            router.pendingDraft = nil
            editor = .draft(draft)
        }
    }

    // MARK: - 导入 CSV

    private func openCSV(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        Task {
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                // 几千行的账单也不卡界面
                let statement = try await Task.detached { try CSVImporter.parse(data) }.value
                csvSession = CSVImportSession(fileName: url.lastPathComponent, statement: statement)
            } catch {
                csvError = error.localizedDescription
            }
        }
    }

    // MARK: - 拍小票

    private func scanReceipt(_ data: Data) {
        scanning = true
        Task {
            defer { scanning = false }
            let expense = categories
                .filter { $0.kind == .expense && !$0.isArchived }
                .map { DSAClient.CategoryRef(id: $0.slug, name: $0.name) }
            do {
                editor = .draft(try await ReceiptScanner.scan(data, categories: expense))
            } catch {
                failedImage = ReceiptScanner.downscaledJPEG(data)
                scanError = error.localizedDescription
            }
        }
    }

    // MARK: - 数据

    /// AUD → 显示货币
    private func convert(_ aud: Double) -> Double { rates.latest.fromBase(aud, to: display) }

    private func show(_ aud: Double) -> String { Money.format(convert(aud), display) }

    private func category(for id: String) -> LedgerCategory? { categories.first { $0.slug == id } }

    private var dayGroups: [(day: Date, entries: [LedgerEntry], expense: Double)] {
        let grouped = Dictionary(grouping: periodEntries) { Calendar.current.startOfDay(for: $0.date) }
        return grouped
            .map { day, list in
                (day, list.sorted { $0.date > $1.date }, list.filter { $0.kind == .expense }.reduce(0) { $0 + $1.baseAmount })
            }
            .sorted { $0.day > $1.day }
    }

    private var categoryBudgetRows: [(category: LedgerCategory, spent: Double, budget: Double)] {
        let spentBy = Dictionary(uniqueKeysWithValues: LedgerStats.byCategory(values, kind: .expense).map { ($0.categoryID, $0.total) })
        return categories.compactMap { c in
            guard let budget = c.monthlyBudget, budget > 0, !c.isArchived else { return nil }
            return (c, spentBy[c.slug] ?? 0, budget)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "creditcard")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(mode == .month ? "这个月还没有记账" : "今年还没有记账")
                .font(.headline)
            Button("记一笔") { editor = .new }
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 24, padding: 22)
    }
}

/// 弹出编辑器的目标
enum EditorTarget: Identifiable {
    case new
    case edit(LedgerEntry)
    /// 拍小票、快捷指令带进来的预填内容
    case draft(EntryDraft)

    var id: String {
        switch self {
        case .new: "new"
        case let .edit(entry): "\(entry.persistentModelID)"
        case let .draft(draft): draft.id.uuidString
        }
    }
}

// MARK: - 邮件自动记账提示

private struct EmailChargeBanner: View {
    let summary: EmailChargeScanner.Summary
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "envelope.badge.fill")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("从邮件自动记了 \(summary.added.count) 笔")
                    .font(.subheadline.weight(.semibold))
                Text(summary.added.prefix(4).joined(separator: "、") + (summary.added.count > 4 ? " 等" : "") + "，不对的话点进去改")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .glassCard(cornerRadius: 20, padding: 14)
    }
}

// MARK: - 时间段切换

private struct PeriodHeader: View {
    @Binding var mode: LedgerView.PeriodMode
    @Binding var anchor: Date

    private var title: String {
        let zh = Locale(identifier: "zh_CN")
        return mode == .month
            ? anchor.formatted(.dateTime.year().month(.wide).locale(zh))
            : anchor.formatted(.dateTime.year().locale(zh))
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.glass)
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .contentTransition(.numericText())
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.glass)
            Picker("周期", selection: $mode.animation()) {
                ForEach(LedgerView.PeriodMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 96)
        }
    }

    private func step(_ n: Int) {
        let component: Calendar.Component = mode == .month ? .month : .year
        withAnimation(.snappy) {
            anchor = Calendar.current.date(byAdding: component, value: n, to: anchor) ?? anchor
        }
    }
}

// MARK: - 收支汇总

private struct SummaryCard: View {
    let totals: Totals
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("支出").font(.caption).foregroundStyle(.secondary)
                Text(format(totals.expense))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }
            HStack(spacing: 28) {
                stat("收入", format(totals.income), .green)
                stat("结余", format(totals.net), totals.net >= 0 ? .primary : .red)
            }
        }
        .glassCard(cornerRadius: 26, padding: 18)
    }

    private func stat(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(tint)
        }
    }
}

// MARK: - 预算

private struct BudgetCard: View {
    let spent: Double
    let budget: Double
    let month: DateInterval
    let categoryBudgets: [(category: LedgerCategory, spent: Double, budget: Double)]
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if budget > 0 {
                let (ratio, level) = LedgerStats.budget(spent: spent, budget: budget)
                HStack {
                    Label("本月预算", systemImage: "target").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(Int((ratio * 100).rounded()))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(level.tint)
                }
                ProgressView(value: min(ratio, 1)).tint(level.tint)
                Text(caption(level: level))
                    .font(.caption)
                    .foregroundStyle(level == .normal ? Color.secondary : level.tint)
            }
            ForEach(categoryBudgets, id: \.category.slug) { row in
                let (ratio, level) = LedgerStats.budget(spent: row.spent, budget: row.budget)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(row.category.name, systemImage: row.category.symbol)
                            .font(.caption)
                            .foregroundStyle(Color(hex: row.category.colorHex))
                        Spacer()
                        Text("\(format(row.spent)) / \(format(row.budget))")
                            .font(.caption)
                            .foregroundStyle(level == .normal ? Color.secondary : level.tint)
                    }
                    ProgressView(value: min(ratio, 1)).tint(level == .normal ? Color(hex: row.category.colorHex) : level.tint)
                }
            }
        }
        .glassCard(cornerRadius: 22, padding: 16)
    }

    private func caption(level: BudgetLevel) -> String {
        let remaining = budget - spent
        if remaining < 0 { return "已超支 \(format(-remaining))" }
        var text = "预算 \(format(budget)) · 剩余 \(format(remaining))"
        if let perDay = LedgerStats.dailyAllowance(remaining: remaining, month: month) {
            text += " · 每天还能花 \(format(perDay))"
        }
        return text
    }
}

private extension BudgetLevel {
    var tint: Color {
        switch self {
        case .normal: .accentColor
        case .warning: .orange
        case .over: .red
        }
    }
}

// MARK: - 分类占比

private struct BreakdownCard: View {
    let values: [EntryValue]
    let category: (String) -> LedgerCategory?
    let convert: (Double) -> Double
    let format: (Double) -> String
    @State private var kind: LedgerKind = .expense

    private var items: [(categoryID: String, total: Double)] { LedgerStats.byCategory(values, kind: kind) }
    private var sum: Double { items.reduce(0) { $0 + $1.total } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("分类").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("类型", selection: $kind.animation()) {
                    ForEach(LedgerKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 120)
            }

            if items.isEmpty {
                Text("没有\(kind.displayName)记录").font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                HStack(alignment: .center, spacing: 18) {
                    Chart(items, id: \.categoryID) { item in
                        SectorMark(angle: .value("金额", convert(item.total)), innerRadius: .ratio(0.62), angularInset: 1.5)
                            .cornerRadius(3)
                            .foregroundStyle(color(item.categoryID))
                    }
                    .frame(width: 130, height: 130)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(kind.displayName).font(.caption2).foregroundStyle(.secondary)
                            Text(format(sum)).font(.caption.weight(.semibold)).minimumScaleFactor(0.6).lineLimit(1)
                        }
                        .frame(width: 76)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(items.prefix(6), id: \.categoryID) { item in
                            HStack(spacing: 6) {
                                Circle().fill(color(item.categoryID)).frame(width: 8, height: 8)
                                Text(category(item.categoryID)?.name ?? "未分类").font(.caption).lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(Int((item.total / max(sum, 0.0001) * 100).rounded()))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .glassCard(cornerRadius: 22, padding: 16)
    }

    private func color(_ id: String) -> Color { Color(hex: category(id)?.colorHex ?? "#8E8E93") }
}

// MARK: - 趋势

private struct TrendCard: View {
    let mode: LedgerView.PeriodMode
    let values: [EntryValue]
    let interval: DateInterval
    let convert: (Double) -> Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .month ? "每日支出" : "每月收支").font(.subheadline.weight(.semibold))
            Group {
                if mode == .month {
                    Chart(LedgerStats.dailyExpense(values, month: interval), id: \.day) { item in
                        BarMark(x: .value("日期", item.day, unit: .day), y: .value("支出", convert(item.total)))
                            .foregroundStyle(Color.orange.gradient)
                            .cornerRadius(2)
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                            AxisValueLabel(format: .dateTime.day())
                        }
                    }
                } else {
                    Chart {
                        ForEach(LedgerStats.monthly(values, year: interval), id: \.month) { row in
                            BarMark(x: .value("月份", row.month, unit: .month), y: .value("金额", convert(row.totals.expense)))
                                .foregroundStyle(by: .value("类型", "支出"))
                                .position(by: .value("类型", "支出"))
                            BarMark(x: .value("月份", row.month, unit: .month), y: .value("金额", convert(row.totals.income)))
                                .foregroundStyle(by: .value("类型", "收入"))
                                .position(by: .value("类型", "收入"))
                        }
                    }
                    .chartForegroundStyleScale(["支出": Color.orange, "收入": Color.green])
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .month, count: 2)) { _ in
                            AxisValueLabel(format: .dateTime.month(.defaultDigits))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Double.self) { Text(Money.compact(v)) } }
                }
            }
            .frame(height: 150)
        }
        .glassCard(cornerRadius: 22, padding: 16)
    }
}

// MARK: - 流水行

struct EntryRow: View {
    let entry: LedgerEntry
    let category: LedgerCategory?
    let display: Currency
    let format: (Double) -> String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category?.symbol ?? "questionmark")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color(hex: category?.colorHex ?? "#8E8E93").gradient, in: .circle)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.merchant.isEmpty ? (category?.name ?? "未分类") : entry.merchant)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                // 有商家时副标题带上分类名；没有商家时标题已经是分类名了，副标题只放时间和备注
                Text(subtitleParts.joined(separator: " · "))
                    .lineLimit(1)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text((entry.kind == .expense ? "-" : "+") + format(entry.baseAmount))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(entry.kind == .expense ? Color.primary : Color.green)
                if entry.currencyValue != display {
                    Text(Money.format(entry.amount, entry.currencyValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .glassCard(cornerRadius: 18, padding: 12)
    }

    private var subtitleParts: [String] {
        var parts = [entry.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().locale(Locale(identifier: "en_GB")))]
        if !entry.merchant.isEmpty { parts.append(category?.name ?? "未分类") }
        if !entry.note.isEmpty { parts.append(entry.note) }
        if entry.source != .manual { parts.append(entry.source.displayName) }
        return parts
    }
}

private struct DayHeader: View {
    let day: Date
    let expense: Double
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(day.formatted(.dateTime.month().day().weekday(.abbreviated).locale(Locale(identifier: "zh_CN"))))
                .font(.subheadline.weight(.semibold))
            Spacer()
            if expense > 0 {
                Text("支出 \(format(expense))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
        .foregroundStyle(.primary)
    }
}

private struct MonthRow: View {
    let month: Date
    let totals: Totals
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(month.formatted(.dateTime.month(.wide).locale(Locale(identifier: "zh_CN"))))
                .font(.body.weight(.medium))
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("支出 \(format(totals.expense))").font(.subheadline)
                Text("收入 \(format(totals.income))").font(.caption).foregroundStyle(.green)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .glassCard(cornerRadius: 18, padding: 14)
    }
}
