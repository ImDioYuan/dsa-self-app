#if DEBUG
import Foundation
import SwiftData

/// Xcode 预览用的假数据
@MainActor
enum PreviewData {
    static let container: ModelContainer = {
        let container = try! ModelContainer(
            for: TaskItem.self, LedgerEntry.self, LedgerCategory.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        for draft in drafts { container.mainContext.insert(TaskItem(draft: draft)) }
        return container
    }()

    static var drafts: [TaskDraft] {
        let now = Date.now
        return [
            TaskDraft(sourceID: "moodle:1", title: "COMP3311 Assignment 2 is due", detail: "COMP3311 Database Systems",
                      source: .ical, kind: .deadline, importance: .critical, due: now.addingTimeInterval(5 * 3600), sourceLabel: "Moodle"),
            TaskDraft(sourceID: "gmail:1", title: "回复 Alex：周六一起吃饭？", detail: "Alex 问周六晚上 7 点在 Haymarket 吃火锅，需要确认是否参加。",
                      source: .gmail, kind: .reply, importance: .important, due: now.addingTimeInterval(30 * 3600)),
            TaskDraft(sourceID: "calendar:1", title: "Tutorial · MATH2089", detail: "Quad 1042",
                      source: .calendar, kind: .meeting, importance: .normal, due: now.addingTimeInterval(50 * 3600)),
            TaskDraft(sourceID: "outlook:1", title: "缴纳 Term 3 学费", detail: "学校缴费系统：截止日期 10 月 20 日。",
                      source: .outlook, kind: .deadline, importance: .critical, due: now.addingTimeInterval(9 * 24 * 3600)),
            TaskDraft(sourceID: "reminders:1", title: "续签手机套餐", source: .reminders, kind: .deadline, importance: .trivial),
        ]
    }
}
#endif
