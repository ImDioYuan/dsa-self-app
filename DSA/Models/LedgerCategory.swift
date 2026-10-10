import Foundation
import SwiftData

/// 记账分类，用户可以增删改、设分类预算
@Model
final class LedgerCategory {
    /// 稳定的标识，LedgerEntry.categoryID 引用它
    var slug: String = ""
    var name: String = ""
    /// SF Symbol 名称
    var symbol: String = "circle"
    var colorHex: String = "#8E8E93"
    var kindRaw: String = LedgerKind.expense.rawValue
    var sortOrder: Int = 0
    /// 分类每月预算（AUD），nil 表示不设
    var monthlyBudget: Double?
    /// 删除分类时只隐藏，旧账仍然能显示分类名
    var isArchived: Bool = false

    init(slug: String, name: String, symbol: String, colorHex: String, kind: LedgerKind, sortOrder: Int) {
        self.slug = slug
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        kindRaw = kind.rawValue
        self.sortOrder = sortOrder
    }

    var kind: LedgerKind { LedgerKind(rawValue: kindRaw) ?? .expense }
}

/// 默认分类
enum DefaultCategories {
    static let all: [(slug: String, name: String, symbol: String, color: String, kind: LedgerKind)] = [
        ("food", "餐饮", "fork.knife", "#FF9500", .expense),
        ("groceries", "买菜", "cart", "#34C759", .expense),
        ("transport", "交通", "tram", "#007AFF", .expense),
        ("shopping", "购物", "bag", "#FF2D55", .expense),
        ("rent", "房租", "house", "#5856D6", .expense),
        ("bills", "账单", "bolt", "#FFCC00", .expense),
        ("entertainment", "娱乐", "gamecontroller", "#AF52DE", .expense),
        ("study", "学习", "book", "#30B0C7", .expense),
        ("health", "医疗", "cross.case", "#FF3B30", .expense),
        ("social", "社交", "person.2", "#FF6482", .expense),
        ("travel", "旅行", "airplane", "#00C7BE", .expense),
        ("other", "其他", "ellipsis.circle", "#8E8E93", .expense),
        ("salary", "工资", "briefcase", "#34C759", .income),
        ("allowance", "生活费", "gift", "#FF9500", .income),
        ("scholarship", "奖学金", "graduationcap", "#007AFF", .income),
        ("refund", "退款", "arrow.uturn.backward", "#30B0C7", .income),
        ("other-income", "其他收入", "plus.circle", "#8E8E93", .income),
    ]

    /// 第一次打开记账页时写入默认分类
    @MainActor
    static func ensureSeeded(in context: ModelContext) {
        let count = (try? context.fetchCount(FetchDescriptor<LedgerCategory>())) ?? 0
        guard count == 0 else { return }
        for (index, c) in all.enumerated() {
            context.insert(LedgerCategory(slug: c.slug, name: c.name, symbol: c.symbol, colorHex: c.color, kind: c.kind, sortOrder: index))
        }
        try? context.save()
    }
}
