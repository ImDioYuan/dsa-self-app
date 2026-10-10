import Foundation

/// app 写、小组件读的支出快照（存在 App Group 的 UserDefaults 里）
struct LedgerSnapshot: Codable, Equatable, Sendable {
    /// App Group 名字写在各 target 的 Info.plist（DSAAppGroup），由 project.yml 按 bundle ID 前缀生成
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "DSAAppGroup") as? String ?? ""
    private static let key = "ledgerSnapshot"

    /// 快照对应的日期（当天 0 点）；过了午夜小组件会把今日支出显示为 0
    var day: Date
    var todayExpense: Double
    var monthExpense: Double
    /// 每月预算，0 表示不设
    var monthBudget: Double
    var currencyCode: String
    var fractionDigits: Int
    var updatedAt: Date

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> LedgerSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LedgerSnapshot.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.defaults?.set(data, forKey: Self.key)
    }

    /// 今天的支出（快照是昨天的就返回 0）
    func todayExpense(now: Date = .now, calendar: Calendar = .current) -> Double {
        calendar.isDate(day, inSameDayAs: now) ? todayExpense : 0
    }

    /// 本月支出（快照是上个月的就返回 0）
    func monthExpense(now: Date = .now, calendar: Calendar = .current) -> Double {
        calendar.isDate(day, equalTo: now, toGranularity: .month) ? monthExpense : 0
    }

    func format(_ value: Double) -> String {
        value.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(fractionDigits))
                .locale(Locale(identifier: "zh_CN"))
        )
    }
}
