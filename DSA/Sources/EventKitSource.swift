import EventKit
import Foundation

/// 苹果日历：未来几天的约会
struct CalendarSource: TaskSourceProvider {
    let source = TaskSource.calendar
    var lookAhead: TimeInterval = 7 * 24 * 3600

    func fetch() async throws -> [TaskDraft] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToEvents() else { return [] }

        let now = Date.now
        let predicate = store.predicateForEvents(
            withStart: Calendar.current.startOfDay(for: now),
            end: now.addingTimeInterval(lookAhead),
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay || Calendar.current.isDateInToday($0.startDate) }
            .compactMap { event -> TaskDraft? in
                guard let id = event.calendarItemExternalIdentifier ?? event.eventIdentifier else { return nil }
                return TaskDraft(
                    // 重复事件每一次的标识相同，拼上开始时间区分
                    sourceID: "calendar:\(id):\(Int(event.startDate.timeIntervalSince1970))",
                    title: event.title ?? "（无标题）",
                    detail: [event.location, event.notes].compactMap { $0 }.joined(separator: "\n"),
                    source: .calendar,
                    kind: .meeting,
                    // 日历里大多是上课、例会这类日常安排；考试、面试按标题升级
                    importance: Importance.guess(title: event.title ?? "", default: .normal),
                    due: event.startDate,
                    link: event.url?.absoluteString
                )
            }
    }
}

/// 苹果提醒事项：未完成且有截止时间（或已过期）的事项
struct RemindersSource: TaskSourceProvider {
    let source = TaskSource.reminders
    var lookAhead: TimeInterval = 7 * 24 * 3600

    func fetch() async throws -> [TaskDraft] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else { return [] }

        let now = Date.now
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: now.addingTimeInterval(lookAhead),
            calendars: nil
        )
        // fetchReminders 是回调式 API；在回调里直接转成值类型再带出来
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                let drafts = (reminders ?? []).map { reminder in
                    let due = reminder.dueDateComponents?.date
                    return TaskDraft(
                        sourceID: "reminders:\(reminder.calendarItemIdentifier)",
                        title: reminder.title ?? "（无标题）",
                        detail: reminder.notes ?? "",
                        source: .reminders,
                        kind: .deadline,
                        importance: Self.importance(of: reminder),
                        due: due,
                        link: reminder.url?.absoluteString
                    )
                }
                continuation.resume(returning: drafts)
            }
        }
    }

    /// 提醒事项的优先级：1-4 高、5 中、6-9 低、0 没设（自己记下来的事默认算重要）
    private static func importance(of reminder: EKReminder) -> Importance {
        switch reminder.priority {
        case 1...4: .critical
        case 5: .important
        case 6...9: .normal
        default: Importance.guess(title: reminder.title ?? "", default: .important)
        }
    }
}
