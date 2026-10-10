import Foundation

/// 四象限（艾森豪威尔矩阵）：纵轴是重要程度（任务自己的属性），横轴是紧急程度（离截止还有多久，随时间变化）
enum Quadrant: Int, CaseIterable, Identifiable, Sendable {
    case doNow = 1, plan, quick, later

    init(important: Bool, urgent: Bool) {
        switch (important, urgent) {
        case (true, true): self = .doNow
        case (true, false): self = .plan
        case (false, true): self = .quick
        case (false, false): self = .later
        }
    }

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .doNow: "马上做"
        case .plan: "计划做"
        case .quick: "尽快处理"
        case .later: "放一放"
        }
    }

    var axes: String {
        switch self {
        case .doNow: "重要 · 紧急"
        case .plan: "重要 · 不紧急"
        case .quick: "紧急 · 不重要"
        case .later: "不重要 · 不紧急"
        }
    }

    var isImportant: Bool { self == .doNow || self == .plan }
    var isUrgent: Bool { self == .doNow || self == .quick }
}

/// 横轴：离截止还有多久，0 在最左、1 在最右。
/// 紧急 / 不紧急的分界（默认 3 天）固定在正中间，两边各用对数刻度：越近的时间分得越细，
/// 「还有 2 小时」和「还有 10 小时」能分开，「还有 12 天」和「还有 15 天」挤在一起也没关系
struct UrgencyScale: Equatable, Sendable {
    /// 离截止不到这么多小时就算紧急
    var horizonHours: Double

    static let horizonOptions: [(hours: Int, label: String)] = [(24, "1 天"), (48, "2 天"), (72, "3 天"), (168, "1 周")]
    static let defaultHorizonHours = 72

    /// 过期的放在 0.015…0.07（过期越久越靠左，最多按 7 天算）
    static let overdueRange = (min: 0.015, max: 0.07)
    static let nowX = 0.09
    /// 30 天及以后
    static let farX = 0.9
    static let farHours = 720.0
    /// 没有截止时间的放在最右边
    static let noDueX = 0.965

    static let divider = 0.5

    func isUrgent(_ due: Date?, now: Date) -> Bool {
        guard let due else { return false }
        return due.timeIntervalSince(now) < horizonHours * 3600
    }

    func x(for due: Date?, now: Date) -> Double {
        guard let due else { return Self.noDueX }
        return x(hours: due.timeIntervalSince(now) / 3600)
    }

    func x(hours h: Double) -> Double {
        if h < 0 {
            let f = log1p(min(-h, 168)) / log1p(168)
            return Self.overdueRange.max - (Self.overdueRange.max - Self.overdueRange.min) * f
        }
        let t = max(horizonHours, 1)
        if h < t {
            return Self.nowX + (Self.divider - Self.nowX) * log1p(h) / log1p(t)
        }
        let far = max(Self.farHours, t + 1)
        let f = log((1 + min(h, far)) / (1 + t)) / log((1 + far) / (1 + t))
        return Self.divider + (Self.farX - Self.divider) * f
    }

    /// 横轴上的刻度。priority 小的先放，放不下的（和已经放好的挤在一起）就不显示——放大后刻度会越来越密
    struct Tick: Identifiable, Equatable {
        var x: Double
        var label: String
        var priority: Int
        var isDivider = false
        var id: String { label }
    }

    var ticks: [Tick] {
        let marks: [(Double, String)] = [
            (1, "1小时"), (3, "3小时"), (6, "6小时"), (12, "12小时"), (24, "1天"), (48, "2天"), (72, "3天"),
            (120, "5天"), (168, "1周"), (336, "2周"), (504, "3周"), (720, "30天"),
        ]
        var ticks = [
            Tick(x: (Self.overdueRange.min + Self.overdueRange.max) / 2, label: "过期", priority: 1),
            Tick(x: Self.nowX, label: "现在", priority: 0),
            Tick(x: Self.noDueX, label: "无期限", priority: 1),
        ]
        for (hours, label) in marks where hours <= Self.farHours {
            let isDivider = abs(hours - horizonHours) < 0.5
            let round = [24.0, 168.0].contains(hours)
            ticks.append(Tick(x: x(hours: hours), label: label, priority: isDivider ? 0 : (round ? 2 : 3), isDivider: isDivider))
        }
        return ticks
    }
}

extension TaskItem {
    func quadrant(_ scale: UrgencyScale, now: Date) -> Quadrant {
        Quadrant(important: importance.isImportant, urgent: scale.isUrgent(due, now: now))
    }
}

/// 截止倒计时：5 分钟后 / 3 小时后 / 2 天后 / 已过期
enum Countdown {
    static func string(to due: Date, now: Date = .now) -> String {
        let seconds = due.timeIntervalSince(now)
        if seconds < 0 { return "已过期" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1)) 分钟后" }
        let hours = Int(seconds / 3600)
        if hours < 48 { return "\(hours) 小时后" }
        return "\(Int(seconds / 86400)) 天后"
    }
}
