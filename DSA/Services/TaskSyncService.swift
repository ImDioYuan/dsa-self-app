import Foundation
import Observation
import SwiftData

/// 从所有已开启的信息源拉取任务，合并进 SwiftData
@MainActor
@Observable
final class TaskSyncService {
    /// 全 app 只有一个同步，任务页、设置页和后台刷新共用，不会两次同步同时跑
    static let shared = TaskSyncService()

    private(set) var isSyncing = false
    /// 每个数据源最近一次的错误，显示在任务页顶部
    private(set) var errors: [TaskSource: String] = [:]
    private var current: Task<Void, Never>?

    private init() {}

    /// 用户手动关掉错误提示
    func dismissErrors() { errors = [:] }

    /// 后台刷新时间用完时调用
    func cancel() { current?.cancel() }

    /// 根据设置组装当前启用的数据源
    static func enabledProviders() -> [any TaskSourceProvider] {
        var providers: [any TaskSourceProvider] = []
        if AppSettings.useCalendar { providers.append(CalendarSource()) }
        if AppSettings.useReminders { providers.append(RemindersSource()) }
        let feeds = AppSettings.icalFeeds
        if !feeds.isEmpty { providers.append(ICalFeedSource(feeds: feeds)) }
        if GoogleAuth.isSignedIn { providers.append(GmailSource()) }
        return providers
    }

    /// 距离上次同步超过 minInterval 才同步（打开 app 时用）
    func syncIfStale(context: ModelContext, minInterval: TimeInterval = 10 * 60) async {
        if let last = AppSettings.lastSyncAt, Date.now.timeIntervalSince(last) < minInterval { return }
        await sync(context: context)
    }

    /// 正在同步时再调用，就等这一次同步结束，不会重新开始。
    /// 同步放在独立的 Task 里：切换页面、下拉刷新结束时 SwiftUI 会取消调用方，
    /// 不能把进行中的同步（尤其是正在等 Claude 分析的 Gmail）一起取消掉
    func sync(context: ModelContext, providers: [any TaskSourceProvider] = TaskSyncService.enabledProviders()) async {
        if let current { return await current.value }
        isSyncing = true
        let task = Task {
            await run(context: context, providers: providers)
            current = nil
            isSyncing = false
        }
        current = task
        await task.value
    }

    private func run(context: ModelContext, providers: [any TaskSourceProvider]) async {
        // 各数据源并行拉取
        let results = await withTaskGroup(of: (TaskSource, Result<[TaskDraft], Error>).self) { group in
            for provider in providers {
                group.addTask {
                    do { return (provider.source, .success(try await provider.fetch())) }
                    catch { return (provider.source, .failure(error)) }
                }
            }
            var all: [(TaskSource, Result<[TaskDraft], Error>)] = []
            for await result in group { all.append(result) }
            return all
        }

        // 同步途中被关掉的数据源，拉回来的结果直接丢掉
        let disabled = Self.disabledSources
        for (source, result) in results where !disabled.contains(source) {
            switch result {
            case let .success(drafts):
                errors[source] = nil
                Self.merge(drafts, from: source, into: context)
            case let .failure(error) where error.isCancellation:
                // 被取消不算失败，下次同步再来
                continue
            case let .failure(error):
                errors[source] = error.localizedDescription
            }
        }
        Self.removeTasks(from: disabled, in: context)
        try? context.save()
        AppSettings.lastSyncAt = .now
    }

    /// 设置里关掉的「全量」数据源：苹果日历、提醒事项、删光了链接的订阅日历
    static var disabledSources: Set<TaskSource> {
        var off: Set<TaskSource> = []
        if !AppSettings.useCalendar { off.insert(.calendar) }
        if !AppSettings.useReminders { off.insert(.reminders) }
        if AppSettings.icalFeeds.isEmpty { off.insert(.ical) }
        return off
    }

    /// 删掉这些数据源带进来的全部任务（包括已完成的）。
    /// 关掉的数据源不会再同步，不删的话它的任务会一直留在今日里
    static func removeTasks(from sources: Set<TaskSource>, in context: ModelContext) {
        guard !sources.isEmpty else { return }
        // 关掉再打开就是重新开始：以前在今日里删掉的也重新显示
        for source in sources { DeletedTasks(source: source).removeAll() }
        let raws = sources.map(\.rawValue)
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { raws.contains($0.sourceRaw) })
        for item in (try? context.fetch(descriptor)) ?? [] { context.delete(item) }
        try? context.save()
    }

    /// 按 sourceID 合并：新的插入、已有的更新（保留完成状态）、
    /// 日历 / 订阅日历这类「全量」数据源里已经消失的未完成任务删掉。
    /// 一个数据源可能产出不同来源的任务（Gmail 转发标签里的邮件算 Outlook），所以按 sourceID 全局匹配。
    static func merge(_ drafts: [TaskDraft], from source: TaskSource, into context: ModelContext) {
        // 同一个 sourceID 有多条时只留一条（优先留已完成的），顺手清掉以前留下的重复
        var byID: [String: TaskItem] = [:]
        for item in (try? context.fetch(FetchDescriptor<TaskItem>())) ?? [] {
            guard let kept = byID[item.sourceID] else {
                byID[item.sourceID] = item
                continue
            }
            if item.isDone && !kept.isDone {
                context.delete(kept)
                byID[item.sourceID] = item
            } else {
                context.delete(item)
            }
        }
        let all = Array(byID.values)
        var seen = Set<String>()
        // 在今日里删掉的，数据源还会再给，跳过
        let deleted = Set(drafts.map(\.source)).reduce(into: Set<String>()) { $0.formUnion(DeletedTasks(source: $1).entries) }
        var seenEntries = Set<String>()

        for draft in drafts {
            seen.insert(draft.sourceID)
            let entry = DeletedTasks.entry(sourceID: draft.sourceID, title: draft.title, due: draft.due)
            seenEntries.insert(entry)
            if deleted.contains(entry) { continue }
            if let item = byID[draft.sourceID] {
                item.apply(draft)
            } else {
                let item = TaskItem(draft: draft)
                context.insert(item)
                byID[draft.sourceID] = item
            }
        }

        if source.isSnapshot {
            for item in all where item.sourceRaw == source.rawValue && !item.isDone && !seen.contains(item.sourceID) {
                context.delete(item)
            }
            DeletedTasks(source: source).keep(only: seenEntries)
        }
    }

    /// 在今日里删掉。日历、提醒事项、订阅日历下次同步还会把还在的事项带回来，重新分析邮件也会，所以先记下来
    static func delete(_ items: [TaskItem], in context: ModelContext) {
        for item in items {
            if item.source != .manual && item.source != .shared {
                DeletedTasks(source: item.source).insert(DeletedTasks.entry(sourceID: item.sourceID, title: item.title, due: item.due))
            }
            context.delete(item)
        }
    }
}

/// 在今日里删掉的任务，按数据源记下来，同步时跳过。记的是 sourceID 加标题和时间：
/// 重复的提醒事项每次都是同一个 sourceID，这样只跳过删掉的那一次；邮件重新分析后几件事的顺序变了也对得上。
/// 全量数据源不再返回的（过期了、源头删了）就忘掉；关掉数据源、或者在设置里点「恢复」时清空
struct DeletedTasks: Sendable {
    let source: TaskSource
    var limit = 500

    var key: String { "deletedTasks.\(source.rawValue)" }

    static func entry(sourceID: String, title: String, due: Date?) -> String {
        "\(sourceID)|\(TaskItem.dedupeKey(title: title, due: due))"
    }

    var entries: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }

    func insert(_ entry: String) {
        var all = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !all.contains(entry) else { return }
        all.append(entry)
        UserDefaults.standard.set(Array(all.suffix(limit)), forKey: key)
    }

    func keep(only entries: Set<String>) {
        let all = UserDefaults.standard.stringArray(forKey: key) ?? []
        let kept = all.filter(entries.contains)
        if kept.count != all.count { UserDefaults.standard.set(kept, forKey: key) }
    }

    func removeAll() { UserDefaults.standard.removeObject(forKey: key) }

    /// 一共删掉了几条（设置里的「恢复」按钮用）
    static var count: Int { TaskSource.allCases.reduce(0) { $0 + DeletedTasks(source: $1).entries.count } }

    static func restoreAll() {
        for source in TaskSource.allCases { DeletedTasks(source: source).removeAll() }
    }
}

extension TaskSource {
    /// 每次拉取都返回完整列表的数据源（没出现就代表被删了或已过期）
    var isSnapshot: Bool {
        switch self {
        case .calendar, .reminders, .ical: true
        case .gmail, .outlook, .shared, .manual: false
        }
    }
}

extension Error {
    /// 任务被取消（切换页面、后台时间用完）：不是真的出错，不用提示
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
