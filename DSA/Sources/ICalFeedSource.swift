import Foundation

/// 订阅日历：Moodle、Canvas、Google 日历、Outlook 等导出的 iCal 链接，读取作业截止时间和日程。
/// 几个链接一起抓；有一个失败就整组报错，免得同步时把这个日历的任务当成「已经消失」删掉
struct ICalFeedSource: TaskSourceProvider {
    let source = TaskSource.ical
    var feeds: [ICalFeed]
    /// 只保留这个时间窗口内的事件
    var lookBack: TimeInterval = 24 * 3600
    var lookAhead: TimeInterval = 21 * 24 * 3600

    func fetch() async throws -> [TaskDraft] {
        try await withThrowingTaskGroup(of: [TaskDraft].self) { group in
            for feed in feeds {
                group.addTask { try await fetch(feed) }
            }
            var all: [TaskDraft] = []
            for try await drafts in group { all += drafts }
            return all
        }
    }

    private func fetch(_ feed: ICalFeed) async throws -> [TaskDraft] {
        guard let url = feed.downloadURL else { throw URLError(.badURL) }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let text = String(decoding: data, as: UTF8.self)
        let now = Date.now
        let label = feed.name.trimmingCharacters(in: .whitespaces)
        return ICalParser.parse(text)
            .filter { event in
                guard let start = event.start else { return false }
                return start > now.addingTimeInterval(-lookBack) && start < now.addingTimeInterval(lookAhead)
            }
            .map { event in
                TaskDraft(
                    // 前缀沿用旧版的 moodle:，已经存下的任务（完成状态、改过的重要程度）都能对上
                    sourceID: "moodle:\(event.uid)",
                    title: event.summary,
                    detail: [event.course, event.description]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n"),
                    source: .ical,
                    kind: .deadline,
                    // 作业、考试很重要；其余要交的东西算重要；「opens」、讲座只算一般
                    importance: Importance.guess(title: event.summary, default: .important),
                    due: event.start,
                    link: event.url,
                    sourceLabel: label.isEmpty ? nil : label
                )
            }
    }
}

// MARK: - iCalendar 解析

struct ICalEvent: Equatable, Sendable {
    var uid: String
    var summary: String
    var description: String?
    var course: String?
    var url: String?
    var start: Date?
    var end: Date?
}

/// 只解析 VEVENT 里 DSA 用得到的字段，足够应付 Moodle / Google / Outlook 导出的 .ics
enum ICalParser {
    static func parse(_ text: String) -> [ICalEvent] {
        var events: [ICalEvent] = []
        var current: [String: (params: [String: String], value: String)]?

        for line in unfold(text) {
            if line == "BEGIN:VEVENT" {
                current = [:]
            } else if line == "END:VEVENT" {
                if let fields = current, let event = makeEvent(fields) { events.append(event) }
                current = nil
            } else if current != nil, let (name, params, value) = splitProperty(line) {
                current?[name] = (params, value)
            }
        }
        return events
    }

    /// RFC 5545：以空格或 Tab 开头的行是上一行的延续
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", !lines.isEmpty {
                lines[lines.count - 1] += raw.dropFirst()
            } else {
                lines.append(String(raw))
            }
        }
        return lines
    }

    /// "DTSTART;TZID=Australia/Sydney:20261005T130000" → ("DTSTART", ["TZID": "Australia/Sydney"], "20261005T130000")
    static func splitProperty(_ line: String) -> (String, [String: String], String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let head = line[..<colon]
        let value = String(line[line.index(after: colon)...])
        var parts = head.split(separator: ";").map(String.init)
        guard !parts.isEmpty else { return nil }
        let name = parts.removeFirst().uppercased()
        var params: [String: String] = [:]
        for part in parts {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (name, params, value)
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func parseDate(_ value: String, params: [String: String]) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)

        if params["VALUE"] == "DATE" || value.count == 8 {
            // 全天事件：当作当天 23:59 截止
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .current
            return formatter.date(from: value).map { $0.addingTimeInterval(24 * 3600 - 60) }
        }
        if value.hasSuffix("Z") {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            formatter.timeZone = TimeZone(identifier: "UTC")
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = params["TZID"].flatMap(TimeZone.init(identifier:)) ?? .current
        }
        return formatter.date(from: value)
    }

    private static func makeEvent(_ f: [String: (params: [String: String], value: String)]) -> ICalEvent? {
        guard let summary = f["SUMMARY"]?.value, !summary.isEmpty else { return nil }
        let start = f["DTSTART"].flatMap { parseDate($0.value, params: $0.params) }
        return ICalEvent(
            uid: f["UID"]?.value ?? "\(summary)-\(start?.timeIntervalSince1970 ?? 0)",
            summary: unescape(summary),
            description: f["DESCRIPTION"].map { unescape($0.value) },
            course: f["CATEGORIES"].map { unescape($0.value) },
            url: f["URL"]?.value,
            start: start,
            end: f["DTEND"].flatMap { parseDate($0.value, params: $0.params) }
        )
    }
}
