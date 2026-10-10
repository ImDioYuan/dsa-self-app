import SwiftData
import SwiftUI

/// 预填内容（拍小票、快捷指令带进来的）
struct EntryDraft: Sendable, Equatable, Identifiable {
    var id = UUID()
    var kind: LedgerKind = .expense
    var amount: Decimal?
    var currency: Currency?
    var categoryID: String?
    var merchant: String = ""
    var note: String = ""
    var date: Date = .now
    var source: EntrySource = .manual
    var receiptImage: Data?
}

/// 记一笔 / 编辑
struct EntryEditor: View {
    let entry: LedgerEntry?
    var draft: EntryDraft?

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var allCategories: [LedgerCategory]
    @AppStorage(LedgerSettingsKey.displayCurrency) private var displayCurrencyRaw = Currency.base.rawValue

    @State private var kind = LedgerKind.expense
    @State private var amountText = ""
    @State private var currency = LedgerSettings.lastCurrency
    @State private var categoryID = ""
    @State private var date = Date.now
    @State private var merchant = ""
    @State private var note = ""
    @State private var receiptImage: Data?
    @State private var source = EntrySource.manual
    /// 用户手动点过分类后，不再根据商家自动切换
    @State private var categoryTouched = false
    @State private var saving = false
    @State private var loaded = false
    @FocusState private var amountFocused: Bool

    private var categories: [LedgerCategory] {
        allCategories.filter { $0.kind == kind && (!$0.isArchived || $0.slug == categoryID) }
    }

    private var amount: Decimal? {
        let normalized = amountText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let value = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), value > 0 else { return nil }
        return value
    }

    private var display: Currency { Currency(rawValue: displayCurrencyRaw) ?? .base }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(LedgerKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                Section {
                    HStack(spacing: 10) {
                        Menu {
                            Picker("币种", selection: $currency) {
                                ForEach(Currency.allCases) { Text($0.label).tag($0) }
                            }
                        } label: {
                            Text(currency.rawValue)
                                .font(.headline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.quaternary, in: .capsule)
                        }
                        TextField("0.00", text: $amountText)
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .multilineTextAlignment(.trailing)
                            .focused($amountFocused)
                            .decimalInput()
                    }
                    if let preview = convertedPreview {
                        Text(preview).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                Section("分类") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 10)], spacing: 10) {
                        ForEach(categories) { c in
                            CategoryChip(category: c, selected: c.slug == categoryID) {
                                categoryID = c.slug
                                categoryTouched = true
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TextField(kind == .expense ? "商家（选填）" : "来源（选填）", text: $merchant)
                        .onChange(of: merchant) { _, newValue in autoCategory(for: newValue) }
                    TextField("备注（选填）", text: $note)
                    DatePicker("时间", selection: $date)
                }

                if let receiptImage, let image = PlatformImage(data: receiptImage) {
                    Section("小票") {
                        Image(platformImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(.rect(cornerRadius: 12))
                    }
                }

                if let entry {
                    Section {
                        Button("删除这笔", role: .destructive) {
                            context.delete(entry)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(entry == nil ? "记一笔" : "编辑")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: save) {
                        if saving { ProgressView() } else { Text("保存") }
                    }
                    .disabled(amount == nil || categoryID.isEmpty || saving)
                }
            }
            .onAppear(perform: load)
            .onChange(of: kind) { _, _ in
                if !categories.contains(where: { $0.slug == categoryID }) { categoryID = categories.first?.slug ?? "" }
            }
        }
        .macSheetFrame(minWidth: 380, minHeight: 560)
        // 弹出页是单独一层，也要跟随主题和浅色 / 深色，切换时才能立刻变
        .themedTint()
    }

    // MARK: - 逻辑

    private var convertedPreview: String? {
        guard let amount, currency != display else { return nil }
        let rates = ExchangeRates.shared.latest
        let aud = NSDecimalNumber(decimal: amount).doubleValue * (rates.rateToBase(currency) ?? 1)
        return "≈ " + Money.format(rates.fromBase(aud, to: display), display)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let entry {
            kind = entry.kind
            amountText = "\(entry.amount)"
            currency = entry.currencyValue
            categoryID = entry.categoryID
            date = entry.date
            merchant = entry.merchant
            note = entry.note
            receiptImage = entry.receiptImage
            source = entry.source
            categoryTouched = true
        } else {
            if let draft {
                kind = draft.kind
                if let a = draft.amount { amountText = "\(a)" }
                if let c = draft.currency { currency = c }
                merchant = draft.merchant
                note = draft.note
                date = draft.date
                receiptImage = draft.receiptImage
                source = draft.source
                if let id = draft.categoryID { categoryID = id; categoryTouched = true }
            }
            if categoryID.isEmpty {
                categoryID = MerchantMemory.category(for: merchant) ?? categories.first?.slug ?? ""
            }
            amountFocused = draft?.amount == nil
        }
    }

    private func autoCategory(for merchant: String) {
        guard !categoryTouched, let id = MerchantMemory.category(for: merchant),
              categories.contains(where: { $0.slug == id }) else { return }
        categoryID = id
    }

    private func save() {
        guard let amount else { return }
        saving = true
        Task {
            let rate = await ExchangeRates.shared.rateToBase(currency, on: date)
            let target: LedgerEntry
            if let entry {
                target = entry
            } else {
                target = LedgerEntry(kind: kind, amount: amount, currency: currency, rateToBase: rate, categoryID: categoryID, source: source)
                context.insert(target)
            }
            target.kind = kind
            target.amount = amount
            target.currency = currency.rawValue
            target.rateToBase = rate
            target.categoryID = categoryID
            target.merchant = merchant.trimmingCharacters(in: .whitespaces)
            target.note = note.trimmingCharacters(in: .whitespaces)
            target.date = date
            target.receiptImage = receiptImage
            try? context.save()

            MerchantMemory.remember(merchant: merchant, categoryID: categoryID)
            LedgerSettings.lastCurrency = currency
            dismiss()
        }
    }
}

// MARK: - 分类按钮

struct CategoryChip: View {
    let category: LedgerCategory
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: category.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? .white : Color(hex: category.colorHex))
                    .frame(width: 40, height: 40)
                    .background(selected ? AnyShapeStyle(Color(hex: category.colorHex).gradient) : AnyShapeStyle(Color(hex: category.colorHex).opacity(0.14)), in: .circle)
                Text(category.name)
                    .font(.caption2)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 跨平台小工具

extension View {
    /// 金额输入框：iOS 上弹数字小数键盘
    func decimalInput() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad)
        #else
        self
        #endif
    }
}

#if os(iOS)
import UIKit
typealias PlatformImage = UIImage
extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#else
import AppKit
typealias PlatformImage = NSImage
extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#endif
