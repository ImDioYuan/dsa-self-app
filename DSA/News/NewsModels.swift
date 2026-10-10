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
    /// 兴趣和地区的名字（App 不认识的 id 按这个显示）
    var categories: [String: LocalizedName]?
    var regions: [String: LocalizedName]?
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
    /// 新闻主要涉及的国家或洲，跨地区是 global（以前的简报没有）
    var region: String?
    /// 猜你喜欢：AI 推断你可能喜欢、但你还没选的兴趣
    var explore: Bool?
    var reasonZh: String?
    var reasonEn: String?

    var isExplore: Bool { explore == true }

    func title(_ language: NewsLanguage) -> String { language.pick(titleZh, titleEn) }
    func summary(_ language: NewsLanguage) -> String { language.pick(summaryZh, summaryEn) }
    func reason(_ language: NewsLanguage) -> String { language.pick(reasonZh ?? "", reasonEn ?? "") }

    /// 地区名（全球的不显示）
    func regionName(_ language: NewsLanguage, names: [String: LocalizedName]?) -> String? {
        guard let region, region != "global" else { return nil }
        return names?[region]?.name(language) ?? readableName(region)
    }
}

struct NewsSource: Codable, Hashable, Sendable {
    var name: String
    var url: String
    var title: String?

    var link: URL? { URL(string: url) }
}

/// 新闻分类 = 兴趣（Worker 的 topics.ts）+ 天气 + 其他；以前的简报里是旧的话题 id。
/// 认识的 id 有专门的名字、图标和颜色；不认识的用简报里带的名字和通用图标
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
        // 时事
        "conflict": Style(zh: "战争冲突", en: "Conflict", symbol: "flame", tint: .red),
        "diplomacy": Style(zh: "国际关系", en: "World affairs", symbol: "globe", tint: .blue),
        "politics": Style(zh: "政治选举", en: "Politics", symbol: "building.columns", tint: .indigo),
        "society": Style(zh: "社会民生", en: "Society", symbol: "person.3", tint: .teal),
        "law": Style(zh: "法律案件", en: "Law & courts", symbol: "scalemass", tint: .brown),
        "disasters": Style(zh: "灾难事故", en: "Disasters", symbol: "exclamationmark.triangle", tint: .orange),
        // 经济
        "economy": Style(zh: "宏观经济", en: "Economy", symbol: "chart.bar", tint: .green),
        "markets": Style(zh: "股市投资", en: "Markets", symbol: "chart.line.uptrend.xyaxis", tint: .green),
        "crypto": Style(zh: "加密货币", en: "Crypto", symbol: "bitcoinsign.circle", tint: .orange),
        "real_estate": Style(zh: "房地产", en: "Property", symbol: "house", tint: .brown),
        "startups": Style(zh: "创业公司", en: "Startups", symbol: "lightbulb", tint: .yellow),
        "personal_finance": Style(zh: "个人理财", en: "Personal finance", symbol: "banknote", tint: .green),
        "careers": Style(zh: "就业职场", en: "Work & careers", symbol: "briefcase", tint: .indigo),
        "shipping": Style(zh: "航运贸易", en: "Shipping & trade", symbol: "shippingbox", tint: .brown),
        "energy": Style(zh: "能源", en: "Energy", symbol: "bolt", tint: .yellow),
        // 科技
        "ai": Style(zh: "AI", en: "AI", symbol: "sparkles", tint: .purple),
        "gadgets": Style(zh: "手机数码", en: "Gadgets", symbol: "iphone", tint: .gray),
        "big_tech": Style(zh: "互联网公司", en: "Big Tech", symbol: "network", tint: .blue),
        "programming": Style(zh: "编程开发", en: "Programming", symbol: "chevron.left.forwardslash.chevron.right", tint: .indigo),
        "cybersecurity": Style(zh: "网络安全", en: "Cybersecurity", symbol: "lock.shield", tint: .red),
        "space": Style(zh: "太空航天", en: "Space", symbol: "moon.stars", tint: .indigo),
        "auto": Style(zh: "汽车电动车", en: "Cars & EVs", symbol: "car", tint: .blue),
        // 科学健康
        "science": Style(zh: "科学发现", en: "Science", symbol: "atom", tint: .teal),
        "climate": Style(zh: "气候环境", en: "Climate", symbol: "leaf", tint: .green),
        "medicine": Style(zh: "医学", en: "Medicine", symbol: "cross.case", tint: .red),
        "mental_health": Style(zh: "心理健康", en: "Mental health", symbol: "brain.head.profile", tint: .pink),
        "fitness": Style(zh: "健身", en: "Fitness", symbol: "figure.run", tint: .orange),
        "nutrition": Style(zh: "饮食营养", en: "Nutrition", symbol: "carrot", tint: .orange),
        // 教育
        "education": Style(zh: "教育政策", en: "Education", symbol: "graduationcap", tint: .teal),
        "study_abroad": Style(zh: "留学移民", en: "Study abroad & visas", symbol: "airplane.departure", tint: .blue),
        "higher_ed": Style(zh: "高校科研", en: "Universities", symbol: "books.vertical", tint: .teal),
        // 文体娱乐
        "sports": Style(zh: "体育", en: "Sports", symbol: "sportscourt", tint: .orange),
        "gaming": Style(zh: "电子游戏", en: "Gaming", symbol: "gamecontroller", tint: .purple),
        "esports": Style(zh: "电竞", en: "Esports", symbol: "trophy", tint: .yellow),
        "film_tv": Style(zh: "电影电视", en: "Film & TV", symbol: "film", tint: .red),
        "music": Style(zh: "音乐", en: "Music", symbol: "music.note", tint: .pink),
        "anime": Style(zh: "动漫", en: "Anime & manga", symbol: "tv", tint: .purple),
        "celebrity": Style(zh: "明星八卦", en: "Celebrity", symbol: "star", tint: .pink),
        "books": Style(zh: "读书", en: "Books", symbol: "book", tint: .brown),
        "art_design": Style(zh: "艺术设计", en: "Art & design", symbol: "paintpalette", tint: .purple),
        // 生活
        "food": Style(zh: "美食", en: "Food", symbol: "fork.knife", tint: .orange),
        "travel": Style(zh: "旅行", en: "Travel", symbol: "suitcase", tint: .teal),
        "fashion": Style(zh: "时尚", en: "Fashion", symbol: "tshirt", tint: .pink),
        "home": Style(zh: "家居", en: "Home", symbol: "sofa", tint: .brown),
        "pets": Style(zh: "宠物", en: "Pets", symbol: "pawprint", tint: .orange),
        "parenting": Style(zh: "育儿", en: "Parenting", symbol: "figure.and.child.holdinghands", tint: .teal),
        // 其他
        "history": Style(zh: "历史文化", en: "History & ideas", symbol: "scroll", tint: .brown),
        "military": Style(zh: "军事", en: "Defence", symbol: "shield", tint: .gray),
        "aviation": Style(zh: "航空", en: "Aviation", symbol: "airplane", tint: .blue),
        "weather": Style(zh: "天气", en: "Weather", symbol: "cloud.bolt.rain", tint: .cyan),
        "other": Style(zh: "其他", en: "Other", symbol: "newspaper", tint: .gray),
        // 以前的简报里的话题
        "international": Style(zh: "国际", en: "World", symbol: "globe", tint: .blue),
        "tech_ai": Style(zh: "科技 AI", en: "Tech & AI", symbol: "cpu", tint: .purple),
        "finance": Style(zh: "财经", en: "Finance", symbol: "chart.line.uptrend.xyaxis", tint: .green),
        "australia": Style(zh: "澳洲", en: "Australia", symbol: "mappin.circle", tint: .orange),
        "china": Style(zh: "中国", en: "China", symbol: "building.2", tint: .pink),
        "us": Style(zh: "美国", en: "United States", symbol: "flag", tint: .indigo),
        "europe": Style(zh: "欧洲", en: "Europe", symbol: "globe.europe.africa", tint: .blue),
        "asia": Style(zh: "亚太", en: "Asia-Pacific", symbol: "globe.asia.australia", tint: .mint),
        "health": Style(zh: "健康", en: "Health", symbol: "cross.case", tint: .red),
        "culture": Style(zh: "文化娱乐", en: "Culture", symbol: "theatermasks", tint: .purple),
    ]

    private var style: Style? { Self.styles[id] }

    /// names：简报里带的名字（App 不认识的 id 用）
    func name(_ language: NewsLanguage, names: [String: LocalizedName]? = nil) -> String {
        style.map { language.pick($0.zh, $0.en) } ?? names?[id]?.name(language) ?? readableName(id)
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

// MARK: - 我的兴趣（GET /news/prefs）

/// 每个兴趣的分数（0–100）和明天几条、常看的地区、建议加入的兴趣
struct NewsPrefs: Decodable, Sendable, Equatable {
    struct Interest: Decodable, Sendable, Equatable, Identifiable {
        var id: String
        var level: Double
        /// 上一次打分前的分数
        var previous: Double
        /// 明天大约几条
        var count: Int
    }

    struct Region: Decodable, Sendable, Equatable, Identifiable {
        var id: String
        var nameZh: String
        var nameEn: String
        /// 占比 0–1
        var share: Double
    }

    struct Suggestion: Decodable, Sendable, Equatable, Identifiable {
        var id: String
        var nameZh: String
        var nameEn: String
    }

    var interests: [Interest]
    /// 每天几条猜你喜欢
    var exploreCount: Int
    var regions: [Region]
    var suggestions: [Suggestion]
}

/// 明天每个兴趣几条，和 Worker 的 allocate（worker/src/prefs.ts）一样：
/// 总条数里留几条给猜你喜欢，其余按分数成比例分；分数低于 10 的不分；分得到的至少 1 条；全降没了就平均分
enum InterestAllocation {
    static let defaultLevel = 50.0
    static let minVisible = 10.0

    static func allocate(_ levels: [(id: String, level: Double)], total: Int, exploreSlots: Int = 2) -> [String: Int] {
        let slots = max(0, total - exploreSlots)
        var result = Dictionary(levels.map { ($0.id, 0) }, uniquingKeysWith: { a, _ in a })
        var active = levels.enumerated().filter { $0.element.level >= minVisible }.map { (index: $0.offset, id: $0.element.id, level: $0.element.level) }
        if active.isEmpty { active = levels.enumerated().map { (index: $0.offset, id: $0.element.id, level: defaultLevel) } }
        guard !active.isEmpty, slots > 0 else { return result }

        let sum = active.reduce(0) { $0 + $1.level }
        let exact = active.map { (item: $0, value: Double(slots) * $0.level / sum) }
        for e in exact { result[e.item.id] = Int(e.value.rounded(.down)) }
        var left = slots - exact.reduce(0) { $0 + Int($1.value.rounded(.down)) }
        let byRemainder = exact.sorted {
            let a = $0.value - $0.value.rounded(.down), b = $1.value - $1.value.rounded(.down)
            if a != b { return a > b }
            if $0.item.level != $1.item.level { return $0.item.level > $1.item.level }
            return $0.item.index < $1.item.index
        }
        for e in byRemainder where left > 0 {
            result[e.item.id, default: 0] += 1
            left -= 1
        }

        // 分得到的兴趣至少 1 条：从条数最多的那里挪
        let ordered = active.sorted { $0.level != $1.level ? $0.level > $1.level : $0.index < $1.index }
        for item in ordered where result[item.id] == 0 {
            guard let donor = ordered.filter({ (result[$0.id] ?? 0) > 1 }).max(by: { (result[$0.id] ?? 0) < (result[$1.id] ?? 0) }) else { break }
            result[donor.id, default: 0] -= 1
            result[item.id] = 1
        }
        return result
    }
}
