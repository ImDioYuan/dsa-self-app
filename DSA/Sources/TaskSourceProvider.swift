import Foundation

/// 每个信息源（Moodle、日历、Gmail……）实现这个协议
protocol TaskSourceProvider: Sendable {
    var source: TaskSource { get }
    /// 拉取最新的任务草稿。没配置好时返回空数组，不要抛错
    func fetch() async throws -> [TaskDraft]
}
