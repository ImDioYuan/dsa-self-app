import SwiftData
import SwiftUI

/// 显示货币、每月预算、分类管理
struct CategoryManager: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]
    @AppStorage(LedgerSettingsKey.displayCurrency) private var displayCurrencyRaw = Currency.base.rawValue
    @AppStorage(LedgerSettingsKey.monthlyBudget) private var monthlyBudget: Double = 0

    @State private var budgetText = ""
    @State private var editing: CategoryTarget?

    private var display: Currency { Currency(rawValue: displayCurrencyRaw) ?? .base }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("显示货币", selection: $displayCurrencyRaw) {
                        ForEach(Currency.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                } footer: {
                    Text("每笔账按记账当天的汇率换算，汇总时再用最新汇率换成显示货币。汇率来自欧洲央行，每天更新。")
                }

                Section {
                    HStack {
                        Text("每月总预算")
                        Spacer()
                        TextField("不设", text: $budgetText)
                            .multilineTextAlignment(.trailing)
                            .decimalInput()
                            .frame(maxWidth: 140)
                        Text(display.rawValue).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("用到 80% 时记账页会变橙色提醒，超支变红。分类预算点进分类里设置。")
                }

                ForEach(LedgerKind.allCases, id: \.self) { kind in
                    Section(kind == .expense ? "支出分类" : "收入分类") {
                        ForEach(visible(kind)) { c in
                            Button { editing = .edit(c) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: c.symbol)
                                        .foregroundStyle(.white)
                                        .frame(width: 28, height: 28)
                                        .background(Color(hex: c.colorHex).gradient, in: .circle)
                                    Text(c.name).foregroundStyle(.primary)
                                    Spacer()
                                    if let budget = c.monthlyBudget {
                                        Text(Money.format(ExchangeRates.shared.latest.fromBase(budget, to: display), display))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                            }
                            .tint(.primary)
                        }
                        .onMove { move(kind: kind, from: $0, to: $1) }
                        .onDelete { offsets in
                            for i in offsets { visible(kind)[i].isArchived = true }
                        }
                        Button {
                            editing = .new(kind)
                        } label: {
                            Label("添加分类", systemImage: "plus")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("分类与预算")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        saveBudget()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if monthlyBudget > 0 {
                    let value = ExchangeRates.shared.latest.fromBase(monthlyBudget, to: display)
                    budgetText = value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
                }
            }
            .sheet(item: $editing) { target in CategoryEditor(target: target) }
        }
        .macSheetFrame(minWidth: 420, minHeight: 560)
        // 弹出页是单独一层，也要跟随主题和浅色 / 深色，切换时才能立刻变
        .themedTint()
    }

    private func visible(_ kind: LedgerKind) -> [LedgerCategory] {
        categories.filter { $0.kind == kind && !$0.isArchived }
    }

    private func move(kind: LedgerKind, from source: IndexSet, to destination: Int) {
        var list = visible(kind)
        list.move(fromOffsets: source, toOffset: destination)
        let base = kind == .expense ? 0 : 1000
        for (i, c) in list.enumerated() { c.sortOrder = base + i }
    }

    /// 预算按显示货币输入，存成 AUD
    private func saveBudget() {
        let value = Double(budgetText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let perAUD = ExchangeRates.shared.latest.perAUD(display) ?? 1
        monthlyBudget = value > 0 ? value / perAUD : 0
    }
}

enum CategoryTarget: Identifiable {
    case new(LedgerKind)
    case edit(LedgerCategory)

    var id: String {
        switch self {
        case let .new(kind): "new-\(kind.rawValue)"
        case let .edit(c): c.slug
        }
    }
}

/// 新建 / 编辑分类
struct CategoryEditor: View {
    let target: CategoryTarget

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var categories: [LedgerCategory]
    @AppStorage(LedgerSettingsKey.displayCurrency) private var displayCurrencyRaw = Currency.base.rawValue

    @State private var name = ""
    @State private var symbol = "tag"
    @State private var colorHex = "#007AFF"
    @State private var budgetText = ""
    @State private var loaded = false

    static let symbols = [
        "fork.knife", "cup.and.saucer", "cart", "bag", "tram", "car", "fuelpump", "airplane", "house", "bolt",
        "wifi", "phone", "gamecontroller", "film", "music.note", "book", "graduationcap", "pencil", "cross.case",
        "pills", "dumbbell", "person.2", "gift", "heart", "pawprint", "tshirt", "scissors", "wrench", "creditcard",
        "briefcase", "banknote", "chart.line.uptrend.xyaxis", "arrow.uturn.backward", "ellipsis.circle", "tag",
    ]
    static let colors = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759", "#00C7BE", "#30B0C7",
        "#007AFF", "#5856D6", "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93",
    ]

    private var kind: LedgerKind {
        switch target {
        case let .new(kind): kind
        case let .edit(c): c.kind
        }
    }

    private var display: Currency { Currency(rawValue: displayCurrencyRaw) ?? .base }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: symbol)
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color(hex: colorHex).gradient, in: .circle)
                        TextField("分类名称", text: $name)
                    }
                }

                if kind == .expense {
                    Section {
                        HStack {
                            Text("每月预算")
                            Spacer()
                            TextField("不设", text: $budgetText)
                                .multilineTextAlignment(.trailing)
                                .decimalInput()
                                .frame(maxWidth: 140)
                            Text(display.rawValue).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("颜色") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.colors, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex).gradient)
                                .frame(width: 30, height: 30)
                                .overlay { if hex == colorHex { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("图标") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 14) {
                        ForEach(Self.symbols, id: \.self) { s in
                            Image(systemName: s)
                                .font(.system(size: 17))
                                .frame(width: 36, height: 36)
                                .foregroundStyle(s == symbol ? .white : .primary)
                                .background(s == symbol ? AnyShapeStyle(Color(hex: colorHex).gradient) : AnyShapeStyle(.quaternary), in: .circle)
                                .onTapGesture { symbol = s }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "新分类" : "编辑分类")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
        .macSheetFrame(minWidth: 380, minHeight: 520)
        // 弹出页是单独一层，也要跟随主题和浅色 / 深色，切换时才能立刻变
        .themedTint()
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private func load() {
        guard !loaded, case let .edit(c) = target else { return }
        loaded = true
        name = c.name
        symbol = c.symbol
        colorHex = c.colorHex
        if let budget = c.monthlyBudget {
            budgetText = ExchangeRates.shared.latest.fromBase(budget, to: display)
                .formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
        }
    }

    private func save() {
        let value = Double(budgetText.replacingOccurrences(of: ",", with: ".")) ?? 0
        let budgetAUD: Double? = value > 0 ? value / (ExchangeRates.shared.latest.perAUD(display) ?? 1) : nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)

        switch target {
        case let .edit(c):
            c.name = trimmed
            c.symbol = symbol
            c.colorHex = colorHex
            c.monthlyBudget = budgetAUD
        case let .new(kind):
            let order = (categories.filter { $0.kind == kind }.map(\.sortOrder).max() ?? 0) + 1
            let c = LedgerCategory(slug: "custom-\(UUID().uuidString.prefix(8).lowercased())", name: trimmed,
                                   symbol: symbol, colorHex: colorHex, kind: kind, sortOrder: order)
            c.monthlyBudget = budgetAUD
            context.insert(c)
        }
        try? context.save()
        dismiss()
    }
}
