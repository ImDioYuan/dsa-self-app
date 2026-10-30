import Foundation

/// 每个信息源（Moodle、日历、Gmail……）实现这个协议
protocol TaskSourceProvider: Sendable {
    var source: TaskSource { get }
    /// 拉取最新的任务草稿。没配置好时返回空数组，不要抛错
    func fetch() async throws -> [TaskDraft]
}

extension Date {
    /// 只有日期的截止时间按当天 23:59 算（Worker 分析邮件时也这样算）。按日历加减，夏令时切换那天也是 23:59
    func lastMinuteOfDay(in calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: self)
        return calendar.date(byAdding: DateComponents(day: 1, minute: -1), to: start) ?? start.addingTimeInterval(24 * 3600 - 60)
    }
}
