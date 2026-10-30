import Foundation

/// 同一件事常常从几个数据源各来一条：Moodle 日历里的「Assignment 2 is due」（课程写在详情里），
/// 和学校邮件（Outlook）里 Claude 写的「提交 COMP3311 作业2」。标题对不上，
/// 所以拆出截止时间、课程代码、作业类型、编号这些线索来比。
struct TaskFingerprint: Sendable {
    var source: TaskSource
    var kind: TaskKind
    var due: Date?
    var isDone: Bool
    /// 精确去重：标题 + 时间精确到分钟
    var key: String
    /// 课程代码，例如 COMP3311。标题和详情里都找（Moodle 的课程写在详情里）
    var courses: Set<String>
    /// 作业类型，中英文归到同一个词：作业 / Assignment → assignment
    var types: Set<String>
    /// 标题里的编号：Assignment 2、Week 5、Lab 05 → 2、5、5。课程代码、日期、时间里的数字不算
    var numbers: Set<Int>
    /// 去掉「is due」「提交」这类词、标点和空格后的标题
    var words: String

    init(title: String, detail: String, source: TaskSource, kind: TaskKind, due: Date?, isDone: Bool) {
        self.source = source
        self.kind = kind
        self.due = due
        self.isDone = isDone
        key = TaskItem.dedupeKey(title: title, due: due)
        let title = title.lowercased()
        // 课程代码先看标题，标题里没有再看详情（Moodle 的课程写在详情里）。
        // 邮件任务的详情是 AI 写的理由，可能顺带提到别的课，标题里有就不看它
        let titleCourses = Set(title.matches(of: Self.coursePattern).map { $0.uppercased() })
        courses = titleCourses.isEmpty ? Set(detail.lowercased().matches(of: Self.coursePattern).map { $0.uppercased() }) : titleCourses
        types = Self.types(in: title)
        numbers = Self.numbers(in: title)
        words = Self.words(in: title)
    }

    /// 邮件里只写了日期时，截止时间按当天 23:59 算，和 Moodle 上的准确时间会差好几个小时
    static let dueTolerance: TimeInterval = 24 * 3600

    func isSameTask(as other: TaskFingerprint) -> Bool {
        // 有一条线索对不上就不是同一件事：不同课程、作业 vs 测验、Assignment 1 vs 2
        func conflict<T>(_ a: Set<T>, _ b: Set<T>) -> Bool { !a.isEmpty && !b.isEmpty && a.isDisjoint(with: b) }

        // 标题和时间都一样（同一个日程订阅在了两个日历里）。两门课同一时间的「Quiz 1 closes」不算。
        // 没有时间的只看标题，一条完成一条没完成的多半是先后两件事（又一封「回复 Alex」）
        if key == other.key { return !conflict(courses, other.courses) && (due != nil || isDone == other.isDone) }

        guard let due, let otherDue = other.due else { return false }
        let gap = abs(due.timeIntervalSince(otherDue))
        guard gap <= Self.dueTolerance,
              kind.isScheduled, other.kind.isScheduled,
              // 同一个 Moodle / 日历里的两条本来就是两件事
              !(source == other.source && source.isSnapshot)
        else { return false }

        if conflict(courses, other.courses) || conflict(types, other.types) || conflict(numbers, other.numbers) {
            return false
        }

        // 至少两条线索对得上，只有课程代码一样（同一门课同一天的另一件事）不算
        var clues = 0
        if !courses.isDisjoint(with: other.courses) { clues += 1 }
        if !types.isDisjoint(with: other.types) { clues += 1 }
        if !numbers.isDisjoint(with: other.numbers) { clues += 1 }
        if gap < 60 { clues += 1 }
        let (short, long) = words.count < other.words.count ? (words, other.words) : (other.words, words)
        if short.count >= 6 && long.contains(short) { clues += 2 }
        return clues >= 2
    }

    // MARK: 拆线索

    private static let coursePattern = "(?<![a-z])[a-z]{4}\\d{4}(?!\\d)"

    private static let typeWords: [(type: String, words: [String])] = [
        ("assignment", ["assignment", "assignments", "assign", "ass", "homework", "hw", "作业"]),
        ("quiz", ["quiz", "quizzes", "test", "测验", "小测", "测试"]),
        ("exam", ["exam", "exams", "examination", "midterm", "考试", "期中", "期末"]),
        ("lab", ["lab", "labs", "实验"]),
        ("project", ["project", "projects", "项目", "大作业"]),
        ("report", ["report", "报告"]),
        ("essay", ["essay", "论文"]),
        ("presentation", ["presentation", "展示", "演讲", "汇报"]),
        ("tutorial", ["tutorial", "tut", "辅导", "习题课"]),
        ("lecture", ["lecture", "讲座", "讲课"]),
        ("forum", ["forum", "discussion", "讨论"]),
    ]

    static func types(in title: String) -> Set<String> {
        let tokens = Set(title.matches(of: "[a-z]+"))
        return Set(typeWords.filter { _, words in
            words.contains { $0.first?.isASCII == true ? tokens.contains($0) : title.contains($0) }
        }.map(\.type))
    }

    /// 这些地方的数字不是编号
    private static let notNumbering = [
        coursePattern,
        "\\d{2}t\\d|\\bt\\d\\b|term\\s*\\d",                                        // 25T3、T3、Term 3
        "\\d{1,4}\\s*[-/年]\\s*\\d{1,2}(\\s*[-/月]\\s*\\d{1,4})?\\s*[日号]?",          // 2026-10-10、10/10、2026年10月
        "\\d{1,2}\\s*月\\s*\\d{1,2}\\s*[日号]?",                                     // 10月10日
        "\\d{1,2}:\\d{2}(\\s*[ap]\\.?m\\.?)?|\\d{1,2}\\s*[ap]\\.?m\\b",              // 17:00、5pm
        "\\d+\\s*(小时|分钟|点|时|日|号|天)",                                          // 5点、3天
        "\\d{1,2}(st|nd|rd|th)\\b",                                                   // 10th
        "\\d{1,2}\\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\s+\\d{1,2}",
        "20\\d{2}",                                                                    // 年份
    ]

    static func numbers(in title: String) -> Set<Int> {
        var text = title
        for pattern in notNumbering {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // 第二次作业、作业二 → 2
        for (n, digit) in "一二三四五六七八九十".enumerated() {
            for prefix in ["第", "作业", "测验", "小测", "实验", "项目", "报告"] {
                text = text.replacingOccurrences(of: "\(prefix)\(digit)", with: "\(prefix) \(n + 1) ")
            }
        }
        return Set(text.matches(of: "\\d{1,4}").compactMap { Int($0) })
    }

    private static let fillerWords: Set<String> = ["is", "due", "closes", "close", "opens", "open", "submit", "submission", "the", "a", "an", "for", "of", "to"]

    static func words(in title: String) -> String {
        var text = title
        for verb in ["提交", "完成", "截止", "参加"] { text = text.replacingOccurrences(of: verb, with: " ") }
        return text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !fillerWords.contains($0) }
            .joined()
    }
}

extension TaskKind {
    /// 有具体时间的事才按时间合并；待回复、信息只按标题精确去重
    var isScheduled: Bool { self == .deadline || self == .meeting }
}

extension TaskSource {
    /// 同一件事有几条时显示哪条：订阅日历 / 日历的时间和链接最准，邮件排后面
    var displayPriority: Int {
        switch self {
        case .ical: 0
        case .calendar: 1
        case .reminders: 2
        case .manual: 3
        case .shared: 4
        case .outlook: 5
        case .gmail: 6
        }
    }
}

enum TaskDuplicates {
    /// 把同一件事的几条归成一组，返回下标。组内第一条是要显示的：
    /// 有一条完成就算整组完成（优先显示完成的那条），其次按数据源 displayPriority
    static func groups(_ prints: [TaskFingerprint]) -> [[Int]] {
        var parent = Array(prints.indices)
        // 每组里各条的课程代码。两门课的组不合并：没写课程的一条（苹果日历里的副本、邮件）不能把它们连起来，
        // 一条同时提到两门课的也不行——两组里每两条带课程的都要有一门课对得上
        var memberCourses = prints.map { $0.courses.isEmpty ? [] : [$0.courses] }
        func courses(_ r: Int) -> Set<String> { memberCourses[r].reduce(into: []) { $0.formUnion($1) } }
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        func join(_ a: Int, _ b: Int) {
            let (ra, rb) = (root(a), root(b))
            guard ra != rb, memberCourses[ra].allSatisfy({ x in memberCourses[rb].allSatisfy { !x.isDisjoint(with: $0) } })
            else { return }
            parent[rb] = ra
            memberCourses[ra] += memberCourses[rb]
        }

        // 没有时间的只能看标题
        var byKey: [String: Int] = [:]
        for i in prints.indices where prints[i].due == nil {
            let key = "\(prints[i].key)|\(prints[i].isDone)"
            if let first = byKey[key] { join(first, i) } else { byKey[key] = i }
        }

        // 有时间的按时间排好，只和 24 小时以内的比，不用两两全比
        let timed = prints.indices.compactMap { i in prints[i].due.map { (i, $0) } }.sorted { $0.1 < $1.1 }
        var pairs: [(Int, Int)] = []
        for (n, (i, due)) in timed.enumerated() {
            for (j, later) in timed[(n + 1)...] {
                guard later.timeIntervalSince(due) <= TaskFingerprint.dueTolerance else { break }
                if prints[i].isSameTask(as: prints[j]) { pairs.append((i, j)) }
            }
        }

        // 先合标题和时间都一样的，日历里没写课程的副本就先归到它原本那门课
        for (i, j) in pairs where prints[i].key == prints[j].key { join(i, j) }

        // 再合靠线索对上的。没写课程的一组同时像两门课的作业时，说不清是哪门课的，单独显示
        let fuzzy = pairs.filter { prints[$0.0].key != prints[$0.1].key }
        var partnerCourses: [Int: [Set<String>]] = [:]
        for (i, j) in fuzzy {
            partnerCourses[root(i), default: []].append(courses(root(j)))
            partnerCourses[root(j), default: []].append(courses(root(i)))
        }
        let ambiguous = Set(partnerCourses.compactMap { r, partners -> Int? in
            let named = partners.filter { !$0.isEmpty }
            return memberCourses[r].isEmpty && named.contains { a in named.contains { a.isDisjoint(with: $0) } } ? r : nil
        })
        for (i, j) in fuzzy where !ambiguous.contains(root(i)) && !ambiguous.contains(root(j)) { join(i, j) }

        var order: [Int] = []
        var members: [Int: [Int]] = [:]
        for i in prints.indices {
            let r = root(i)
            if members[r] == nil { order.append(r) }
            members[r, default: []].append(i)
        }
        return order.map { r in
            let group = members[r] ?? []
            let done = group.contains { prints[$0].isDone }
            return group.sorted {
                (prints[$0].isDone == done ? 0 : 1, prints[$0].source.displayPriority, $0)
                    < (prints[$1].isDone == done ? 0 : 1, prints[$1].source.displayPriority, $1)
            }
        }
    }
}

extension TaskItem {
    var fingerprint: TaskFingerprint {
        TaskFingerprint(title: title, detail: detail, source: source, kind: kind, due: due, isDone: isDone)
    }

    /// 同一件事的几条归成一组，每组第一条是要显示的（见 TaskDuplicates）
    static func grouped(_ items: [TaskItem]) -> [[TaskItem]] {
        TaskDuplicates.groups(items.map(\.fingerprint)).map { $0.map { items[$0] } }
    }
}

private extension String {
    func matches(of pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = self as NSString
        return regex.matches(in: self, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
