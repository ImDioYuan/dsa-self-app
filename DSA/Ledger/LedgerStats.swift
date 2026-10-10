import Foundation

/// 统计用的值类型（和 SwiftData 解耦，方便测试）
struct EntryValue: Sendable, Equatable {
    var kind: LedgerKind
    /// AUD 金额
    var baseAmount: Double
    var categoryID: String
    var date: Date
}

struct Totals: Equatable {
    var income: Double = 0
    var expense: Double = 0
    var net: Double { income - expense }
}

enum BudgetLevel: Equatable {
    case normal, warning, over
}

/// 记账统计。所有金额都是 AUD，显示前再换算
enum LedgerStats {
    static func totals(_ entries: [EntryValue]) -> Totals {
        entries.reduce(into: Totals()) { t, e in
            switch e.kind {
            case .income: t.income += e.baseAmount
            case .expense: t.expense += e.baseAmount
            }
        }
    }

    /// 某个时间段内的记录
    static func filter(_ entries: [EntryValue], in interval: DateInterval) -> [EntryValue] {
        entries.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    /// 按分类汇总，金额从大到小
    static func byCategory(_ entries: [EntryValue], kind: LedgerKind) -> [(categoryID: String, total: Double)] {
        var sums: [String: Double] = [:]
        for e in entries where e.kind == kind { sums[e.categoryID, default: 0] += e.baseAmount }
        return sums.map { ($0.key, $0.value) }.sorted { $0.total > $1.total }
    }

    /// 一个月里每天的支出（没有支出的天也返回 0）
    static func dailyExpense(_ entries: [EntryValue], month: DateInterval, calendar: Calendar = .current) -> [(day: Date, total: Double)] {
        var sums: [Date: Double] = [:]
        for e in filter(entries, in: month) where e.kind == .expense {
            sums[calendar.startOfDay(for: e.date), default: 0] += e.baseAmount
        }
        var result: [(Date, Double)] = []
        var day = calendar.startOfDay(for: month.start)
        while day < month.end {
            result.append((day, sums[day] ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    /// 一年里每个月的收入和支出
    static func monthly(_ entries: [EntryValue], year: DateInterval, calendar: Calendar = .current) -> [(month: Date, totals: Totals)] {
        var result: [(Date, Totals)] = []
        var month = year.start
        while month < year.end {
            guard let next = calendar.date(byAdding: .month, value: 1, to: month) else { break }
            result.append((month, totals(filter(entries, in: DateInterval(start: month, end: next)))))
            month = next
        }
        return result
    }

    /// 预算使用比例和提醒级别（超过 80% 提醒，超过 100% 超支）
    static func budget(spent: Double, budget: Double) -> (ratio: Double, level: BudgetLevel) {
        guard budget > 0 else { return (0, .normal) }
        let ratio = spent / budget
        return (ratio, ratio >= 1 ? .over : ratio >= 0.8 ? .warning : .normal)
    }

    /// 本月剩下的天里，平均每天还能花多少（含今天）
    static func dailyAllowance(remaining: Double, month: DateInterval, now: Date = .now, calendar: Calendar = .current) -> Double? {
        guard remaining > 0, now < month.end else { return nil }
        let today = calendar.startOfDay(for: max(now, month.start))
        let days = calendar.dateComponents([.day], from: today, to: month.end).day ?? 0
        return days > 0 ? remaining / Double(days) : nil
    }

    static func monthInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }

    static func yearInterval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .year, for: date) ?? DateInterval(start: date, duration: 0)
    }
}
