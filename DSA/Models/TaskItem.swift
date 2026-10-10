import Foundation
import SwiftData

/// 任务从哪里来
enum TaskSource: String, Codable, CaseIterable, Sendable {
    /// 订阅日历的 raw value 沿用旧版的 "moodle"，已经存下的任务不用迁移
    case gmail, outlook, ical = "moodle", calendar, reminders, shared, manual

    var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .outlook: "Outlook"
        case .ical: "订阅日历"
        case .calendar: "日历"
        case .reminders: "提醒事项"
        case .shared: "分享"
        case .manual: "手动"
        }
    }

    var systemImage: String {
        switch self {
        case .gmail: "envelope"
        case .outlook: "envelope.badge"
        case .ical: "calendar.badge.clock"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .shared: "square.and.arrow.down"
        case .manual: "pencil"
        }
    }
}

/// 任务类型
enum TaskKind: String, Codable, CaseIterable, Sendable {
    case deadline, meeting, reply, info

    var displayName: String {
        switch self {
        case .deadline: "截止"
        case .meeting: "约会"
        case .reply: "待回复"
        case .info: "信息"
        }
    }
}

/// 重要程度：只看这件事本身有多重要、错过的后果有多大，和还剩多少时间无关。
/// 紧急程度不存，按截止时间实时算（见 Quadrant.swift），两者组成四象限。
/// 旧版本是 1 一般 / 2 重要 / 3 紧急，启动时由 migrateImportanceScale 整体 +1 换算
enum Importance: Int, Codable, CaseIterable, Comparable, Sendable {
    case trivial = 1, normal = 2, important = 3, critical = 4

    var displayName: String {
        switch self {
        case .trivial: "不重要"
        case .normal: "一般"
        case .important: "重要"
        case .critical: "很重要"
        }
    }

    /// 四象限的上半边
    var isImportant: Bool { self >= .important }

    static func < (lhs: Importance, rhs: Importance) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 没有 AI 判断的数据源（订阅日历、日历、提醒事项）按标题里的关键词估计。
    /// 「Quiz 1 opens」这类只是开放、不用交东西的先排除
    static func guess(title: String, default fallback: Importance) -> Importance {
        let text = title.lowercased()
        if text.range(of: minorPattern, options: .regularExpression) != nil { return .normal }
        if text.range(of: criticalPattern, options: .regularExpression) != nil { return .critical }
        return fallback
    }

    private static let minorPattern = "\\b(opens?|lecture|seminar|webinar|forum|attendance|reading)\\b|讲座|开放|阅读"
    private static let criticalPattern = "\\b(exams?|final|midterm|mid-term|assignments?|assessments?|projects?|essay|report|presentation|interview|visa|rent)\\b|考试|期中|期末|作业|面试|签证|房租|学费"
}

/// 存在 SwiftData 里的任务。
/// 所有属性都有默认值、没有 unique 约束，以后可以直接打开 CloudKit 同步。
@Model
final class TaskItem {
    /// 去重用的唯一标识，例如 "gmail:<messageId>"、"moodle:<UID>"（订阅日历沿用旧前缀）
    var sourceID: String = ""
    var title: String = ""
    var detail: String = ""
    var sourceRaw: String = TaskSource.manual.rawValue
    /// 来源的具体名字，例如订阅日历的「Moodle」；nil 就显示来源类型
    var sourceLabel: String?
    var kindRaw: String = TaskKind.info.rawValue
    var importanceRaw: Int = Importance.important.rawValue
    /// 用户手动改过重要程度：同步时不再用数据源的值覆盖
    var importanceLocked: Bool = false
    var due: Date?
    var link: String?
    var isDone: Bool = false
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(draft: TaskDraft) {
        sourceID = draft.sourceID
        createdAt = .now
        apply(draft)
    }

    var source: TaskSource { TaskSource(rawValue: sourceRaw) ?? .manual }
    var sourceName: String { sourceLabel ?? source.displayName }
    var kind: TaskKind { TaskKind(rawValue: kindRaw) ?? .info }
    /// 通过这里改的都算用户手动改的（数据源的值走 apply）
    var importance: Importance {
        get { Importance(rawValue: importanceRaw) ?? .important }
        set {
            importanceRaw = newValue.rawValue
            importanceLocked = true
        }
    }
    var url: URL? { link.flatMap(URL.init(string:)) }

    /// 用数据源最新的内容覆盖（保留完成状态）
    func apply(_ draft: TaskDraft) {
        title = draft.title
        detail = draft.detail
        sourceRaw = draft.source.rawValue
        sourceLabel = draft.sourceLabel
        kindRaw = draft.kind.rawValue
        if !importanceLocked { importanceRaw = draft.importance.rawValue }
        due = draft.due
        link = draft.link
        updatedAt = .now
    }
}

extension TaskItem {
    private static let importanceScaleKey = "importanceScale"

    /// 旧数据是 1 一般 / 2 重要 / 3 紧急，换成新的四档：整体 +1（紧急的多半也很重要）。
    /// 日历、订阅日历、提醒事项下次同步会重新估计；Gmail 分析过的邮件不会再分析，靠这里换算
    @MainActor
    static func migrateImportanceScale(in context: ModelContext) {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: importanceScaleKey) < 2 else { return }
        for item in (try? context.fetch(FetchDescriptor<TaskItem>())) ?? [] {
            item.importanceRaw = min(Importance.critical.rawValue, item.importanceRaw + 1)
        }
        try? context.save()
        defaults.set(2, forKey: importanceScaleKey)
    }

    /// 标题（忽略大小写、空格和标点）+ 时间精确到分钟：一样就算同一件事
    static func dedupeKey(title: String, due: Date?) -> String {
        let name = String(title.lowercased().unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        })
        return "\(name)|\(due.map { String(Int($0.timeIntervalSince1970 / 60)) } ?? "-")"
    }
}

/// 数据源产出的任务草稿（值类型，可以跨线程传递）
struct TaskDraft: Sendable, Hashable {
    var sourceID: String
    var title: String
    var detail: String = ""
    var source: TaskSource
    var kind: TaskKind
    var importance: Importance
    var due: Date?
    var link: String?
    /// 来源的具体名字（订阅日历的名字）
    var sourceLabel: String?
}
