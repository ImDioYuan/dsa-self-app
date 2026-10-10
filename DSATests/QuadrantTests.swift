import Foundation
import SwiftData
import Testing
@testable import DSA

@Suite("四象限")
@MainActor
struct QuadrantTests {
    let now = Date(timeIntervalSince1970: 1_791_000_000)
    let scale = UrgencyScale(horizonHours: 72)

    @Test func timeAxisIsMonotonicWithDividerInTheMiddle() {
        let hours: [Double] = [-200, -24, -1, 0, 0.5, 1, 6, 24, 48, 71.9, 72, 100, 168, 336, 720, 5000]
        let xs = hours.map(scale.x(hours:))
        #expect(xs == xs.sorted())
        #expect(abs(scale.x(hours: 72) - 0.5) < 0.0001)
        #expect(scale.x(hours: -1) < UrgencyScale.nowX)
        #expect(scale.x(hours: 5000) == UrgencyScale.farX)
        #expect(scale.x(for: nil, now: now) == UrgencyScale.noDueX)
        // 换一个分界，分界仍在中间
        #expect(abs(UrgencyScale(horizonHours: 24).x(hours: 24) - 0.5) < 0.0001)
        #expect(abs(UrgencyScale(horizonHours: 168).x(hours: 168) - 0.5) < 0.0001)
    }

    @Test func quadrantFollowsImportanceAndTimeLeft() {
        func task(_ importance: Importance, hours: Double?) -> TaskItem {
            TaskItem(draft: TaskDraft(sourceID: UUID().uuidString, title: "t", source: .manual, kind: .deadline,
                                      importance: importance, due: hours.map { now.addingTimeInterval($0 * 3600) }))
        }
        #expect(task(.critical, hours: 5).quadrant(scale, now: now) == .doNow)
        #expect(task(.important, hours: -3).quadrant(scale, now: now) == .doNow)
        #expect(task(.important, hours: 100).quadrant(scale, now: now) == .plan)
        #expect(task(.critical, hours: nil).quadrant(scale, now: now) == .plan)
        #expect(task(.normal, hours: 10).quadrant(scale, now: now) == .quick)
        #expect(task(.trivial, hours: 400).quadrant(scale, now: now) == .later)
        // 同一件事，时间过去了就从「计划做」变成「马上做」
        let essay = task(.critical, hours: 80)
        #expect(essay.quadrant(scale, now: now) == .plan)
        #expect(essay.quadrant(scale, now: now.addingTimeInterval(10 * 3600)) == .doNow)
    }

    @Test func guessesImportanceFromTitle() {
        #expect(Importance.guess(title: "COMP3311 Assignment 2 is due", default: .important) == .critical)
        #expect(Importance.guess(title: "MATH2089 Final Exam", default: .normal) == .critical)
        #expect(Importance.guess(title: "Quiz 3 closes", default: .important) == .important)
        #expect(Importance.guess(title: "Quiz 3 opens", default: .important) == .normal)
        #expect(Importance.guess(title: "Assignment 2 opens", default: .important) == .normal)
        #expect(Importance.guess(title: "COMP3311 Lecture", default: .important) == .normal)
        #expect(Importance.guess(title: "交房租", default: .important) == .critical)
        // 单词里包含关键词不算
        #expect(Importance.guess(title: "Reopening party", default: .important) == .important)
        #expect(Importance.guess(title: "Parental leave", default: .important) == .important)
    }

    @Test func syncKeepsImportanceTheUserPicked() {
        let draft = TaskDraft(sourceID: "moodle:1", title: "Quiz 1", source: .ical, kind: .deadline, importance: .important)
        let item = TaskItem(draft: draft)
        var updated = draft
        updated.importance = .normal
        item.apply(updated)
        #expect(item.importance == .normal)

        item.importance = .critical
        item.apply(updated)
        #expect(item.importance == .critical)
    }

    @Test func oldImportanceScaleIsShiftedOnce() throws {
        UserDefaults.standard.removeObject(forKey: "importanceScale")
        defer { UserDefaults.standard.set(2, forKey: "importanceScale") }
        let container = try ModelContainer(for: TaskItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        for (n, old) in [1, 2, 3].enumerated() {
            let item = TaskItem(draft: TaskDraft(sourceID: "gmail:\(n)", title: "t\(n)", source: .gmail, kind: .reply, importance: .trivial))
            item.importanceRaw = old
            context.insert(item)
        }
        TaskItem.migrateImportanceScale(in: context)
        TaskItem.migrateImportanceScale(in: context)
        let values = try context.fetch(FetchDescriptor<TaskItem>()).map(\.importanceRaw).sorted()
        #expect(values == [2, 3, 4])
    }

    // MARK: 排布

    private func matrixTasks(_ specs: [(Importance, Double?)], in context: ModelContext) -> [MatrixTask] {
        specs.enumerated().map { n, spec in
            let item = TaskItem(draft: TaskDraft(sourceID: "manual:\(n)", title: "任务 \(n)", source: .manual, kind: .deadline,
                                                 importance: spec.0, due: spec.1.map { now.addingTimeInterval($0 * 3600) }))
            context.insert(item)
            return MatrixTask(id: item.persistentModelID, title: item.title, due: item.due, importance: item.importance,
                              quadrant: item.quadrant(scale, now: now), x: scale.x(for: item.due, now: now))
        }
    }

    private func chipsOverlap(_ layout: MatrixLayout) -> Bool {
        let chip = MatrixLayout.chipSize(layout.detail)
        let frames = layout.nodes.map { node -> CGRect in
            let size: CGSize = if case .cluster = node.kind { CGSize(width: 34, height: 34) } else { chip }
            return CGRect(x: node.center.x - size.width / 2, y: node.center.y - size.height / 2, width: size.width, height: size.height)
        }
        for i in frames.indices {
            for j in frames.indices where j > i && frames[i].insetBy(dx: 1, dy: 1).intersects(frames[j].insetBy(dx: 1, dy: 1)) {
                return true
            }
        }
        return false
    }

    @Test func zoomingOutMergesAndZoomingInSplits() throws {
        let container = try ModelContainer(for: TaskItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        // 很重要那一条里，今天下午挤着 5 件事；另外散着几件
        let specs: [(Importance, Double?)] = [
            (.critical, 3), (.critical, 3.5), (.critical, 4), (.critical, 4), (.critical, 5),
            (.critical, 70), (.critical, 75), (.important, 200), (.normal, nil), (.trivial, -5), (.trivial, -6),
        ]
        let tasks = matrixTasks(specs, in: container.mainContext)
        let size = CGSize(width: 330, height: 272)

        let overview = MatrixLayout(tasks: tasks, size: size, zoom: 1, offset: .zero)
        #expect(overview.detail == .dots)
        let clusters = overview.nodes.filter { if case .cluster = $0.kind { true } else { false } }
        #expect(!clusters.isEmpty)
        #expect(overview.nodes.count < tasks.count)
        #expect(!chipsOverlap(overview))
        // 每个任务都在，且只出现一次
        let ids = overview.nodes.flatMap { node -> [PersistentIdentifier] in
            switch node.kind {
            case let .task(task): [task.id]
            case let .cluster(members): members.map(\.id)
            }
        }
        #expect(Set(ids) == Set(tasks.map(\.id)))
        #expect(ids.count == tasks.count)

        // 气泡不跨中线：70 小时（紧急）和 75 小时（不紧急）分在两边
        for node in overview.nodes {
            if case let .cluster(members) = node.kind {
                #expect(Set(members.map(\.quadrant)).count == 1)
            }
        }

        var previous = overview.nodes.count
        for zoom in [1.6, 2.5, 4.0, MatrixLayout.maxZoom] {
            let layout = MatrixLayout(tasks: tasks, size: size, zoom: zoom, offset: .zero)
            #expect(layout.nodes.count >= previous)
            #expect(!chipsOverlap(layout))
            previous = layout.nodes.count
        }
        let closest = MatrixLayout(tasks: tasks, size: size, zoom: MatrixLayout.maxZoom, offset: .zero)
        #expect(closest.nodes.count == tasks.count)
    }

    @Test func widerPlotShowsMoreDetailWithoutZooming() throws {
        let container = try ModelContainer(for: TaskItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let tasks = matrixTasks([(.critical, 3), (.important, 100)], in: container.mainContext)
        #expect(MatrixLayout(tasks: tasks, size: CGSize(width: 330, height: 272), zoom: 1, offset: .zero).detail == .dots)
        let wide = MatrixLayout(tasks: tasks, size: CGSize(width: 1000, height: 700), zoom: 1, offset: .zero)
        #expect(wide.detail != .dots)
        #expect(!chipsOverlap(wide))
    }

    @Test func clampKeepsContentInView() {
        let size = CGSize(width: 300, height: 200)
        #expect(MatrixLayout.clamp(CGPoint(x: 50, y: 50), zoom: 2, size: size) == .zero)
        #expect(MatrixLayout.clamp(CGPoint(x: -900, y: -900), zoom: 2, size: size) == CGPoint(x: -300, y: -200))
        #expect(MatrixLayout.clamp(CGPoint(x: -10, y: -10), zoom: 1, size: size) == .zero)
    }
}
