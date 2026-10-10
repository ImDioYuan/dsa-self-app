import SwiftData
import SwiftUI

/// 导入 CSV：看识别结果、改分类、勾选要导入的行
struct CSVImportSheet: View {
    @Bindable var session: CSVImportSession
    /// 导入了几笔、其中最近的日期
    var onImported: (Int, Date?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LedgerCategory.sortOrder) private var categories: [LedgerCategory]

    private var selectedCount: Int { session.selected.count }
    private var selectable: [CSVTransaction] { session.rows.filter { $0.status != .imported } }
    private var allSelected: Bool { !selectable.isEmpty && selectable.allSatisfy(\.include) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("文件") { Text(session.fileName).lineLimit(1).truncationMode(.middle) }
                    LabeledContent("识别为", value: session.format)
                    if let range = dateRange {
                        LabeledContent("时间", value: range)
                    }
                    LabeledContent("交易") {
                        Text("支出 \(session.rows.count { $0.kind == .expense }) 笔 · 收入 \(session.rows.count { $0.kind == .income }) 笔")
                    }
                    if session.hasRowsWithoutCurrency {
                        Picker("币种", selection: $session.currency) {
                            ForEach(Currency.allCases) { Text($0.label).tag($0) }
                        }
                    }
                    if session.hasSignBasedRows {
                        Toggle("收入和支出对调", isOn: Binding(get: { session.flipped }, set: { _ in session.toggleFlip() }))
                    }
                } footer: {
                    Text(footer)
                }

                if session.isClassifying {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在让 Claude 给商家分类…").foregroundStyle(.secondary)
                        }
                    }
                } else if let note = session.classifyNote {
                    Section {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ForEach(session.rows) { row in
                        CSVTransactionRow(
                            row: row,
                            currency: session.currency(of: row),
                            category: categories.first { $0.slug == row.categoryID },
                            choices: categories.filter { $0.kind == row.kind && (!$0.isArchived || $0.slug == row.categoryID) },
                            isClassifying: session.isClassifying,
                            onToggle: { session.toggle(row.id) },
                            onCategory: { session.setCategory($0, for: row) }
                        )
                    }
                } header: {
                    HStack {
                        Text("交易")
                        Spacer()
                        Button(allSelected ? "全不选" : "全选") { session.setAll(include: !allSelected) }
                            .font(.footnote)
                            .textCase(nil)
                            .disabled(selectable.isEmpty)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("导入 CSV")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(session.isImporting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: commit) {
                        if session.isImporting { ProgressView() } else { Text("导入 \(selectedCount) 笔") }
                    }
                    .disabled(selectedCount == 0 || session.isClassifying || session.isImporting)
                }
            }
            .task { session.start() }
        }
        .interactiveDismissDisabled(session.isImporting)
        .macSheetFrame(minWidth: 460, minHeight: 560)
        .themedTint()
    }

    private var dateRange: String? {
        guard let first = session.rows.map(\.date).min(), let last = session.rows.map(\.date).max() else { return nil }
        let style = Date.FormatStyle.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))
        return Calendar.current.isDate(first, inSameDayAs: last)
            ? first.formatted(style)
            : "\(first.formatted(style)) – \(last.formatted(style))"
    }

    private var footer: String {
        var parts: [String] = []
        if session.skipped > 0 { parts.append("跳过了 \(session.skipped) 行（不计收支、交易关闭、金额为 0 等）。") }
        let duplicates = session.rows.count { $0.status != .new }
        if duplicates > 0 { parts.append("\(duplicates) 笔已经记过（以前导入过，或 Apple Pay / 邮件已记），默认不勾选。") }
        if session.hasSignBasedRows { parts.append("收支是按金额正负号判断的，如果反了打开「对调」。") }
        return parts.joined(separator: "\n")
    }

    private func commit() {
        Task {
            let result = await session.commit()
            onImported(result.count, result.latest)
            dismiss()
        }
    }
}

private struct CSVTransactionRow: View {
    let row: CSVTransaction
    let currency: Currency
    let category: LedgerCategory?
    let choices: [LedgerCategory]
    let isClassifying: Bool
    let onToggle: () -> Void
    let onCategory: (String) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Form 里一行有多个按钮时要用 borderless，不然点哪里都会触发所有按钮
            Button(action: onToggle) {
                Image(systemName: row.include ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(row.include ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .disabled(row.status == .imported)
            .accessibilityLabel(row.include ? "取消勾选" : "勾选")

            VStack(alignment: .leading, spacing: 4) {
                Text(row.merchant)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(row.date.formatted(.dateTime.month().day().locale(Locale(identifier: "zh_CN"))))
                        .foregroundStyle(.secondary)
                    categoryMenu
                    switch row.status {
                    case .new: EmptyView()
                    case .imported: badge("已导入", .secondary)
                    case .likelyDuplicate: badge("可能已记过", .orange)
                    }
                }
                .font(.caption)
                if !row.note.isEmpty {
                    Text(row.note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text((row.kind == .expense ? "-" : "+") + Money.format(row.amount, currency))
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(row.kind == .expense ? Color.primary : Color.green)
                .lineLimit(1)
        }
        .opacity(row.include ? 1 : 0.6)
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
    }

    private var categoryMenu: some View {
        let tint = Color(hex: category?.colorHex ?? "#8E8E93")
        return Menu {
            Picker("分类", selection: Binding(get: { row.categoryID }, set: onCategory)) {
                ForEach(choices) { Label($0.name, systemImage: $0.symbol).tag($0.slug) }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: category?.symbol ?? "ellipsis")
                Text(category?.name ?? (isClassifying ? "分类中…" : "未分类"))
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: .capsule)
        }
        .buttonStyle(.borderless)
        .disabled(category == nil && isClassifying)
    }

    private func badge(_ text: String, _ tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.12), in: .capsule)
    }
}
