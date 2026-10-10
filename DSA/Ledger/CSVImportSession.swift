import Foundation
import Observation
import SwiftData

/// 一次 CSV 导入：识别结果 → 商家分类（本地记忆 + Claude）→ 标出已记过的 → 写进账本
@MainActor
@Observable
final class CSVImportSession: Identifiable {
    let id = UUID()
    let fileName: String
    let format: String
    let skipped: Int
    private(set) var rows: [CSVTransaction]
    /// 文件里没写币种的行用这个，用户可以改
    var currency: Currency {
        didSet { if currency != oldValue { markDuplicates() } }
    }

    private(set) var flipped = false
    private(set) var isClassifying = false
    private(set) var classifyNote: String?
    private(set) var isImporting = false
    private var classifyTask: Task<Void, Never>?
    private var generation = 0

    init(fileName: String, statement: CSVStatement) {
        self.fileName = fileName
        format = statement.format
        skipped = statement.skipped
        rows = statement.transactions
        currency = statement.defaultCurrency
    }

    var hasSignBasedRows: Bool { rows.contains(where: \.signBased) }
    var hasRowsWithoutCurrency: Bool { rows.contains { $0.currency == nil } }
    var selected: [CSVTransaction] { rows.filter { $0.include && $0.status != .imported } }

    func currency(of row: CSVTransaction) -> Currency { row.currency ?? currency }

    func start() {
        guard generation == 0 else { return }
        markDuplicates()
        classify()
    }

    // MARK: - 用户操作

    func toggle(_ id: Int) {
        guard let i = rows.firstIndex(where: { $0.id == id }), rows[i].status != .imported else { return }
        rows[i].include.toggle()
    }

    func setAll(include: Bool) {
        for i in rows.indices where rows[i].status != .imported { rows[i].include = include }
    }

    /// 改一行的分类：同一个商家的其他行一起改，并记住（下次 Apple Pay / 导入直接用）
    func setCategory(_ slug: String, for row: CSVTransaction) {
        let name = row.merchant.lowercased()
        for i in rows.indices where rows[i].kind == row.kind && (rows[i].id == row.id || rows[i].merchant.lowercased() == name) {
            rows[i].categoryID = slug
        }
        if row.kind == .expense { MerchantMemory.remember(merchant: row.merchant, categoryID: slug) }
    }

    /// 收入和支出对调（银行和信用卡的正负号习惯相反，自动判断错了时用）
    func toggleFlip() {
        flipped.toggle()
        rows = CSVImporter.flipSigns(rows)
        for i in rows.indices where rows[i].signBased { rows[i].categoryID = "" }
        markDuplicates()
        classify()
    }

    // MARK: - 分类

    private func classify() {
        classifyTask?.cancel()
        generation += 1
        let current = generation
        classifyTask = Task { await runClassification(generation: current) }
    }

    private func runClassification(generation current: Int) async {
        isClassifying = true
        classifyNote = nil
        defer { if current == generation { isClassifying = false } }

        // 用户改过的商家分类优先，不用问 Claude
        for i in rows.indices where rows[i].categoryID.isEmpty && rows[i].kind == .expense {
            if let remembered = MerchantMemory.category(for: rows[i].merchant) { rows[i].categoryID = remembered }
        }

        let pending = rows.filter { $0.categoryID.isEmpty }
        guard !pending.isEmpty else { return }

        guard let client = try? DSAClient.fromSettings() else {
            classifyNote = "没有配置 AI 服务，先归到「其他」，导入前可以点分类修改"
            fillFallbackCategories()
            return
        }

        var failed: String?
        for kind in LedgerKind.allCases {
            let refs = LedgerStore.activeCategories(kind: kind).map { DSAClient.CategoryRef(id: $0.slug, name: $0.name) }
            // 同样的描述只问一次
            var keys: [String] = []
            var samples: [String: CSVTransaction] = [:]
            for row in pending where row.kind == kind {
                let key = Self.key(row)
                if samples[key] == nil {
                    keys.append(key)
                    samples[key] = row
                }
            }
            guard !keys.isEmpty, !refs.isEmpty else { continue }

            for start in stride(from: 0, to: keys.count, by: 200) {
                let batch = Array(keys[start..<min(start + 200, keys.count)])
                let items = batch.enumerated().map { index, key in
                    let row = samples[key]!
                    let text = row.note.isEmpty ? row.rawDescription : "\(row.merchant) · \(row.note)"
                    return DSAClient.CategorizeItem(id: "\(index)", merchant: text, amount: NSDecimalNumber(decimal: row.amount).doubleValue)
                }
                do {
                    let results = try await client.categorize(items, categories: refs)
                    guard current == generation else { return }
                    for result in results {
                        guard let index = Int(result.id), batch.indices.contains(index) else { continue }
                        apply(result, toKey: batch[index], kind: kind)
                    }
                } catch let error where error.isCancellation {
                    return
                } catch {
                    failed = error.localizedDescription
                }
            }
        }
        guard current == generation else { return }
        if let failed { classifyNote = "AI 分类失败（\(failed)），没分好的先归到「其他」" }
        fillFallbackCategories()
        // 商家名整理过之后，和 Apple Pay 记的对得更准
        markDuplicates()
    }

    private func apply(_ result: DSAClient.CategorizeResult, toKey key: String, kind: LedgerKind) {
        for i in rows.indices where rows[i].kind == kind && rows[i].categoryID.isEmpty && Self.key(rows[i]) == key {
            rows[i].categoryID = result.categoryId
            // 支付宝 / 微信的交易对方本来就是干净的商家名；银行流水用 Claude 整理过的（WOOLWORTHS 1234 SYDNEY → Woolworths）
            if !result.merchant.isEmpty, format != "支付宝", format != "微信支付" {
                rows[i].merchant = result.merchant
            }
        }
    }

    private func fillFallbackCategories() {
        let expense = Self.fallbackCategory(.expense)
        let income = Self.fallbackCategory(.income)
        for i in rows.indices where rows[i].categoryID.isEmpty {
            rows[i].categoryID = rows[i].kind == .expense ? expense : income
        }
    }

    private static func fallbackCategory(_ kind: LedgerKind) -> String {
        let active = LedgerStore.activeCategories(kind: kind)
        let preferred = kind == .expense ? "other" : "other-income"
        return active.first { $0.slug == preferred }?.slug ?? active.last?.slug ?? preferred
    }

    private static func key(_ row: CSVTransaction) -> String {
        (row.rawDescription + "|" + row.merchant).lowercased()
    }

    // MARK: - 去重

    /// 导入过的同一行（externalID 一样）不能再选；金额、日期、商家和已有记录对得上的默认不勾
    private func markDuplicates() {
        guard let earliest = rows.map(\.date).min(), let latest = rows.map(\.date).max() else { return }
        let from = earliest.addingTimeInterval(-3 * 86_400)
        let to = latest.addingTimeInterval(3 * 86_400)
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= from && $0.date <= to })
        let entries = (try? LedgerStore.context.fetch(descriptor)) ?? []
        let imported = Set(entries.compactMap(\.externalID))
        let existing = entries.map {
            EmailChargeScanner.ExistingEntry(kind: $0.kind, amount: $0.amount, currency: $0.currencyValue, merchant: $0.merchant, date: $0.date)
        }

        for i in rows.indices {
            let row = rows[i]
            let status: CSVTransaction.Status
            if imported.contains(row.externalID) {
                status = .imported
            } else if [row.merchant, row.rawDescription].contains(where: { isDuplicate(row, merchant: $0, existing: existing) }) {
                status = .likelyDuplicate
            } else {
                status = .new
            }
            if status != row.status {
                rows[i].status = status
                rows[i].include = status == .new
            }
        }
    }

    private func isDuplicate(_ row: CSVTransaction, merchant: String, existing: [EmailChargeScanner.ExistingEntry]) -> Bool {
        let candidate = EmailChargeScanner.Candidate(
            kind: row.kind, amount: row.amount, currency: currency(of: row), merchant: merchant,
            date: row.date, categoryID: row.categoryID, note: row.note, externalID: row.externalID
        )
        return EmailChargeScanner.isDuplicate(candidate, of: existing)
    }

    // MARK: - 写入

    /// 返回导入的笔数和其中最近的日期（导入后跳到那个月）
    func commit() async -> (count: Int, latest: Date?) {
        isImporting = true
        defer { isImporting = false }
        let context = LedgerStore.context
        DefaultCategories.ensureSeeded(in: context)
        fillFallbackCategories()
        let chosen = selected

        // 外币账单：一次拉好这段时间的历史汇率，不用一天请求一次
        let foreign = chosen.filter { currency(of: $0) != .base }
        if let from = foreign.map(\.date).min(), let to = foreign.map(\.date).max() {
            await ExchangeRates.shared.preloadHistory(from: from, to: to)
        }

        var added: [Date] = []
        for row in chosen where !LedgerStore.exists(externalID: row.externalID) {
            let currency = currency(of: row)
            let rate = await ExchangeRates.shared.rateToBase(currency, on: row.date)
            context.insert(LedgerEntry(
                kind: row.kind, amount: row.amount, currency: currency, rateToBase: rate, categoryID: row.categoryID,
                merchant: row.merchant, note: row.note, date: row.date, source: .csv, externalID: row.externalID
            ))
            added.append(row.date)
        }
        try? context.save()
        LedgerSnapshotWriter.update(context: context)
        return (added.count, added.max())
    }
}
