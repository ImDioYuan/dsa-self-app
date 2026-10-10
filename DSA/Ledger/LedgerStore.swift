import Foundation
import SwiftData

/// 不经过界面的记账入口（快捷指令、Apple Pay 自动化、CSV 导入）
@MainActor
enum LedgerStore {
    static var context: ModelContext { DSAApp.container.mainContext }

    /// 记一笔。externalID 已存在时视为重复，返回 nil
    @discardableResult
    static func add(
        kind: LedgerKind = .expense,
        amount: Decimal,
        currency: Currency,
        categoryID: String,
        merchant: String = "",
        note: String = "",
        date: Date = .now,
        source: EntrySource,
        externalID: String? = nil
    ) async -> LedgerEntry? {
        DefaultCategories.ensureSeeded(in: context)
        if let externalID, exists(externalID: externalID) { return nil }

        let rate = await ExchangeRates.shared.rateToBase(currency, on: date)
        let entry = LedgerEntry(
            kind: kind, amount: amount, currency: currency, rateToBase: rate, categoryID: categoryID,
            merchant: merchant, note: note, date: date, source: source, externalID: externalID
        )
        context.insert(entry)
        try? context.save()
        LedgerSnapshotWriter.update(context: context)
        return entry
    }

    static func exists(externalID: String) -> Bool {
        let target: String? = externalID
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.externalID == target })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    static func category(slug: String) -> LedgerCategory? {
        let descriptor = FetchDescriptor<LedgerCategory>(predicate: #Predicate { $0.slug == slug })
        return try? context.fetch(descriptor).first
    }

    static func activeCategories(kind: LedgerKind) -> [LedgerCategory] {
        DefaultCategories.ensureSeeded(in: context)
        let raw = kind.rawValue
        let descriptor = FetchDescriptor<LedgerCategory>(
            predicate: #Predicate { $0.kindRaw == raw && !$0.isArchived },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// 商家 → 分类：先查本地记忆，没有就问 Claude（最多等 6 秒），再不行归到「其他」。
    /// 返回分类 id 和整理后的商家名
    static func classify(merchant: String, amount: Double?) async -> (categoryID: String, merchant: String) {
        let fallback = activeCategories(kind: .expense).first { $0.slug == "other" }?.slug ?? "other"
        if let remembered = MerchantMemory.category(for: merchant) { return (remembered, merchant) }

        let refs = activeCategories(kind: .expense).map { DSAClient.CategoryRef(id: $0.slug, name: $0.name) }
        guard let client = try? DSAClient.fromSettings(), !refs.isEmpty else { return (fallback, merchant) }

        let result = await withTimeout(seconds: 6) {
            try await client.categorize([.init(id: "1", merchant: merchant, amount: amount)], categories: refs).first
        }
        guard let result else { return (fallback, merchant) }
        MerchantMemory.remember(merchant: merchant, categoryID: result.categoryId)
        return (result.categoryId, result.merchant.isEmpty ? merchant : result.merchant)
    }
}

/// 超时就返回 nil（出错也返回 nil）
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { try? await operation() }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
