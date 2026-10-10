import Foundation
import SwiftData
#if canImport(WidgetKit)
import WidgetKit
#endif

/// 把今日 / 本月支出写进 App Group，给桌面和锁屏小组件用
@MainActor
enum LedgerSnapshotWriter {
    static func update(context: ModelContext = DSAApp.container.mainContext, now: Date = .now) {
        let calendar = Calendar.current
        let month = LedgerStats.monthInterval(containing: now, calendar: calendar)
        let start = month.start
        let end = month.end
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= start && $0.date < end })
        let values = ((try? context.fetch(descriptor)) ?? []).map(\.value)

        let today = calendar.startOfDay(for: now)
        let todayValues = values.filter { calendar.isDate($0.date, inSameDayAs: today) }

        let display = LedgerSettings.displayCurrency
        let rates = ExchangeRates.shared.latest
        let snapshot = LedgerSnapshot(
            day: today,
            todayExpense: rates.fromBase(LedgerStats.totals(todayValues).expense, to: display),
            monthExpense: rates.fromBase(LedgerStats.totals(values).expense, to: display),
            monthBudget: rates.fromBase(LedgerSettings.monthlyBudget, to: display),
            currencyCode: display.rawValue,
            fractionDigits: display.fractionDigits,
            updatedAt: now
        )
        guard snapshot.withoutTimestamp != LedgerSnapshot.load()?.withoutTimestamp else { return }
        snapshot.save()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

private extension LedgerSnapshot {
    /// 比较时忽略更新时间，内容没变就不刷新小组件
    var withoutTimestamp: LedgerSnapshot {
        var copy = self
        copy.updatedAt = .distantPast
        return copy
    }
}
