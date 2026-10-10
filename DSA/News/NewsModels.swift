import Foundation
import SwiftUI

/// 简报和深度报道的显示语言，一键切换
enum NewsLanguage: String, CaseIterable, Sendable {
    case zh, en

    static let storageKey = "news.language"

    /// 选当前语言的文字；这一种是空的就用另一种
    func pick(_ zh: String, _ en: String) -> String {
        switch self {
        case .zh: zh.isEmpty ? en : zh
        case .en: en.isEmpty ? zh : en
        }
    }

    var locale: Locale { Locale(identifier: self == .zh ? "zh_CN" : "en_AU") }
}

// MARK: - 简报

struct NewsBrief: Codable, Sendable, Equatable {
    struct Stats: Codable, Sendable, Equatable {
        var feeds: Int
        var failedFeeds: [String]
        var headlines: Int
        var costUSD: Double
        /// false：模型不在 Worker 的价格表里，花费不准（以前的简报没有这个字段）
        var priced: Bool?
    }

    /// 用户时区的日期 YYYY-MM-DD
    var date: String
    var generatedAt: Date
    var items: [NewsItem]
    var impact: NewsImpact
    var weather: [CityWeather]
    var fx: [FXRate]
    /// 「对你的影响」各方面的名字（用户在设置里自己定的；以前的简报没有）
    var interests: [String: LocalizedName]?
    var stats: Stats?
}

/// 中英文名字
struct LocalizedName: Codable, Hashable, Sendable {
    var nameZh: String
    var nameEn: String

    func name(_ language: NewsLanguage) -> String { language.pick(nameZh, nameEn) }
}

struct NewsItem: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var rank: Int
    var category: NewsCategory
    /// 1–5，5 最重要
    var importance: Int
    var titleZh: String
    var titleEn: String
    var summaryZh: String
    var summaryEn: String
    var sources: [NewsSource]
    var affectsMe: Bool

    func title(_ language: NewsLanguage) -> String { language.pick(titleZh, titleEn) }
    func summary(_ language: NewsLanguage) -> String { language.pick(summaryZh, summaryEn) }
}

struct NewsSource: Codable, Hashable, Sendable {
    var name: String
    var url: String
    var title: String?

    var link: URL? { URL(string: url) }
}

/// 新闻分类 = 用户选的话题（Worker 的 topics.ts）+ 天气 + 其他。
/// 认识的 id 有专门的名字、图标和颜色；Worker 以后加了新话题，App 没更新时显示 id 和通用图标
struct NewsCategory: Codable, Hashable, Sendable {
    var id: String

    init(_ id: String) { self.id = id }

    init(from decoder: Decoder) throws {
        id = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }

    static let weather = NewsCategory("weather")

    private struct Style {
        var zh: String
        var en: String
        var symbol: String
        var tint: Color
    }

    private static let styles: [String: Style] = [
        "conflict": Style(zh: "战争冲突", en: "Conflict", symbol: "flame", tint: .red),
        "international": Style(zh: "国际", en: "World", symbol: "globe", tint: .blue),
        "tech_ai": Style(zh: "科技 AI", en: "Tech & AI", symbol: "cpu", tint: .purple),
        "finance": Style(zh: "财经", en: "Finance", symbol: "chart.line.uptrend.xyaxis", tint: .green),
        "education": Style(zh: "教育", en: "Education", symbol: "graduationcap", tint: .teal),
        "australia": Style(zh: "澳洲", en: "Australia", symbol: "mappin.circle", tint: .orange),
        "china": Style(zh: "中国", en: "China", symbol: "building.2", tint: .pink),
        "us": Style(zh: "美国", en: "United States", symbol: "flag", tint: .indigo),
        "europe": Style(zh: "欧洲", en: "Europe", symbol: "globe.europe.africa", tint: .blue),
        "asia": Style(zh: "亚太", en: "Asia-Pacific", symbol: "globe.asia.australia", tint: .mint),
        "shipping": Style(zh: "航运贸易", en: "Shipping & Trade", symbol: "shippingbox", tint: .brown),
        "science": Style(zh: "科学", en: "Science", symbol: "atom", tint: .teal),
        "health": Style(zh: "健康", en: "Health", symbol: "cross.case", tint: .red),
        "sports": Style(zh: "体育", en: "Sports", symbol: "sportscourt", tint: .orange),
        "culture": Style(zh: "文化娱乐", en: "Culture", symbol: "theatermasks", tint: .purple),
        "weather": Style(zh: "天气", en: "Weather", symbol: "cloud.bolt.rain", tint: .cyan),
        "other": Style(zh: "其他", en: "Other", symbol: "newspaper", tint: .gray),
    ]

    private var style: Style? { Self.styles[id] }

    func name(_ language: NewsLanguage) -> String {
        style.map { language.pick($0.zh, $0.en) } ?? readableName(id)
    }

    var systemImage: String { style?.symbol ?? "newspaper" }
    var tint: Color { style?.tint ?? .gray }
}

// MARK: - 对我的影响

struct NewsImpact: Codable, Hashable, Sendable {
    struct Point: Codable, Hashable, Sendable {
        var area: ImpactArea
        var titleZh: String
        var titleEn: String
        var detailZh: String
        var detailEn: String
        /// 相关新闻的序号（从 1 开始）
        var itemRanks: [Int]

        func title(_ language: NewsLanguage) -> String { language.pick(titleZh, titleEn) }
        func detail(_ language: NewsLanguage) -> String { language.pick(detailZh, detailEn) }
    }

    var overviewZh: String
    var overviewEn: String
    var points: [Point]

    func overview(_ language: NewsLanguage) -> String { language.pick(overviewZh, overviewEn) }
}

/// 「对你的影响」的一个方面。名字来自简报里的 interests（用户自己在设置里定的）；
/// 常见的 id 有专门的图标和颜色，其他的用通用图标
struct ImpactArea: Codable, Hashable, Sendable {
    var id: String

    init(_ id: String) { self.id = id }

    init(from decoder: Decoder) throws {
        id = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(id)
    }

    private struct Style {
        var zh: String
        var en: String
        var symbol: String
        var tint: Color
    }

    private static let styles: [String: Style] = [
        "ai_tools": Style(zh: "AI 工具", en: "AI tools", symbol: "sparkles", tint: .purple),
        "markets": Style(zh: "市场", en: "Markets", symbol: "chart.line.uptrend.xyaxis", tint: .green),
        "study": Style(zh: "学业", en: "Study", symbol: "graduationcap", tint: .teal),
        "career": Style(zh: "工作", en: "Career", symbol: "briefcase", tint: .indigo),
        "business": Style(zh: "生意", en: "Business", symbol: "shippingbox", tint: .orange),
        "life": Style(zh: "生活", en: "Life", symbol: "house", tint: .blue),
        "weather": Style(zh: "天气", en: "Weather", symbol: "cloud.sun", tint: .cyan),
    ]

    private var style: Style? { Self.styles[id] }

    /// names：简报里带的名字（优先）
    func name(_ language: NewsLanguage, names: [String: LocalizedName]?) -> String {
        if let custom = names?[id] { return custom.name(language) }
        return style.map { language.pick($0.zh, $0.en) } ?? readableName(id)
    }

    var systemImage: String { style?.symbol ?? "circle.hexagongrid" }
    var tint: Color { style?.tint ?? .orange }
}

/// 没有名字的 id 直接显示："family_business" → "Family Business"
private func readableName(_ id: String) -> String {
    id.replacingOccurrences(of: "_", with: " ").capitalized
}

// MARK: - 天气 / 汇率

struct CityWeather: Codable, Hashable, Sendable, Identifiable {
    struct Day: Codable, Hashable, Sendable {
        var date: String
        /// WMO 天气代码
        var code: Int
        var max: Double
        var min: Double
        var precip: Double
        var gust: Double
    }

    var city: String
    var nameZh: String
    var nameEn: String
    var extreme: Bool
    var noteZh: String
    var noteEn: String
    var days: [Day]

    var id: String { city }
    func name(_ language: NewsLanguage) -> String { language.pick(nameZh, nameEn) }
    func note(_ language: NewsLanguage) -> String { language.pick(noteZh, noteEn) }

    /// WMO 天气代码 → SF Symbol
    static func symbol(for code: Int) -> String {
        switch code {
        case 0: "sun.max.fill"
        case 1, 2: "cloud.sun.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 61, 63, 66, 80, 81: "cloud.rain.fill"
        case 65, 67, 82: "cloud.heavyrain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }
}

struct FXRate: Codable, Hashable, Sendable {
    var pair: String
    var rate: Double
    /// 一周涨跌（%）
    var change7d: Double?
}

// MARK: - 深度报道

struct NewsReport: Codable, Sendable, Equatable {
    struct Section: Codable, Sendable, Hashable {
        var headingZh: String
        var headingEn: String
        var bodyZh: String
        var bodyEn: String

        func heading(_ language: NewsLanguage) -> String { language.pick(headingZh, headingEn) }

        /// 正文按空行分段
        func paragraphs(_ language: NewsLanguage) -> [String] {
            language.pick(bodyZh, bodyEn)
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    var titleZh: String
    var titleEn: String
    var sections: [Section]
    var impactZh: String
    var impactEn: String
    var sources: [NewsSource]
    var generatedAt: Date
    /// 生成这篇花了多少（以前生成的报道没有）
    var stats: Stats?

    struct Stats: Codable, Sendable, Equatable {
        var costUSD: Double
        /// false：模型不在 Worker 的价格表里，花费不准
        var priced: Bool?
    }

    func impact(_ language: NewsLanguage) -> String { language.pick(impactZh, impactEn) }
}

extension NewsReport {
    private enum CodingKeys: String, CodingKey {
        case titleZh, titleEn, sections, impactZh, impactEn, sources, generatedAt, stats
    }

    /// 解码时顺手修好模型写坏的地方（已经缓存的旧报道也能修好）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titleZh = try c.decode(String.self, forKey: .titleZh)
        titleEn = try c.decode(String.self, forKey: .titleEn)
        sections = try c.decode([Section].self, forKey: .sections).map {
            Section(
                headingZh: $0.headingZh, headingEn: $0.headingEn,
                bodyZh: Self.unescape($0.bodyZh), bodyEn: Self.unescape($0.bodyEn)
            )
        }
        (impactZh, impactEn) = Self.repairImpact(
            zh: try c.decode(String.self, forKey: .impactZh),
            en: try c.decode(String.self, forKey: .impactEn)
        )
        sources = try c.decode([NewsSource].self, forKey: .sources)
        generatedAt = try c.decode(Date.self, forKey: .generatedAt)
        stats = try c.decodeIfPresent(Stats.self, forKey: .stats)
    }

    /// 模型有时把换行写成字面上的 \n，把引号写成 \"
    static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// impactZh 有时一口气写过了头，把 `","impactEn":"…英文…"}`（或 `<parameter name="impactEn">…`）也写进去，真正的 impactEn 只剩 "placeholder"。
    /// 从 impactZh 里把英文切出来
    static func repairImpact(zh: String, en: String) -> (String, String) {
        var zh = zh, en = en
        if let leak = zh.range(of: #""\s*,(?:\s|\\n)*(?:"impactEn"\s*:\s*"|<parameter name="impactEn">)"#, options: .regularExpression) {
            var leaked = String(zh[leak.upperBound...])
            zh = String(zh[..<leak.lowerBound])
            if let tail = leaked.range(of: #"(?:</parameter>|"\s*\}?)\s*$"#, options: .regularExpression) {
                leaked.removeSubrange(tail)
            }
            let trimmedEn = en.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedEn.isEmpty || trimmedEn.lowercased() == "placeholder" || trimmedEn.count < leaked.count / 2 {
                en = leaked
            }
        }
        return (unescape(zh).trimmingCharacters(in: .whitespacesAndNewlines),
                unescape(en).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// 列表 → 详情的导航值：哪一天的哪条新闻
struct NewsRoute: Hashable {
    var date: String
    var item: NewsItem
}

/// "2026-10-03" → 10月3日 星期六 / Sat 3 Oct
enum NewsDate {
    static func date(from string: String) -> Date? { parser.date(from: string) }

    static func title(_ string: String, language: NewsLanguage) -> String {
        guard let date = date(from: string) else { return string }
        return switch language {
        case .zh: date.formatted(.dateTime.month().day().weekday(.wide).locale(language.locale))
        case .en: date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(language.locale))
        }
    }

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
