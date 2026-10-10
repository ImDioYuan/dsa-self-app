import Foundation
import Observation

/// 存在自己的 Worker 里的配置（worker/src/config.ts 的 UserConfig）：个人资料、新闻设置、AI 服务。
/// 字段和 Worker 一一对应；Worker 会给缺的字段补默认值、丢掉不合法的值
struct UserConfig: Codable, Equatable, Sendable {
    var name = ""
    var about = ""
    var timezone = TimeZone.current.identifier
    var watchRules: [String] = []
    var news = News()
    var ai = AI()
    var updatedAt = ""

    struct News: Codable, Equatable, Sendable {
        var topics: [String] = []
        var customFeeds: [CustomFeed] = []
        var count = 20
        var places: [Place] = []
        var fxPairs: [String] = []
        var interests: [Interest] = []
        /// 每天几点之前生成好简报，HH:mm
        var briefTime = "08:00"
    }

    struct CustomFeed: Codable, Hashable, Sendable {
        var name: String
        var url: String
    }

    struct Place: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var nameZh: String
        var nameEn: String
        var lat: Double
        var lon: Double
        var country: String
        var admin1: String
    }

    /// 「对你的影响」的一个方面
    struct Interest: Codable, Hashable, Identifiable, Sendable {
        var id: String
        var nameZh: String
        var nameEn: String
        var hint: String
    }

    struct ModelChoice: Codable, Equatable, Sendable {
        var provider: String
        var model: String
    }

    /// 三组功能各用哪家的哪个模型；nil = 用第一家配了 key 的服务商的默认模型
    struct AI: Codable, Equatable, Sendable {
        var tasks: ModelChoice?
        var brief: ModelChoice?
        var report: ModelChoice?
    }

    /// 限制和 Worker 的校验一致
    static let maxWatchRules = 10
    static let maxPlaces = 4
    static let maxFxPairs = 6
    static let maxInterests = 6
    static let maxCustomFeeds = 10
    static let countRange = 5...30
}

/// GET / PUT /config 的返回
struct ConfigResponse: Decodable, Sendable {
    var config: UserConfig
    var providers: [AIProvider]
    var topics: [NewsTopic]
}

struct AIProvider: Decodable, Identifiable, Sendable {
    struct Model: Decodable, Hashable, Sendable {
        var id: String
        /// 美元 / 百万 token
        var input: Double
        var output: Double
        var vision: Bool
    }

    var id: String
    var name: String
    /// Worker 里的 secret 名字，例如 OPENAI_API_KEY
    var keyName: String
    var configured: Bool
    var webSearch: Bool
    var defaults: [String: String]
    var models: [Model]
}

struct NewsTopic: Decodable, Identifiable, Sendable {
    var id: String
    var nameZh: String
    var nameEn: String
    /// 这个话题有几个新闻源
    var feeds: Int
}

/// 三组功能
enum AITask: String, CaseIterable, Identifiable, Sendable {
    case tasks, brief, report

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tasks: "任务和记账"
        case .brief: "每日简报"
        case .report: "深度报道"
        }
    }

    var footnote: String {
        switch self {
        case .tasks: "分析邮件、给商家分类、识别小票和扣费邮件。用量大，适合便宜的小模型；拍小票需要能看图的模型。"
        case .brief: "每天一次，从几百条标题里挑新闻、写中英双语简报。Claude 会用 Batch API 半价生成。"
        case .report: "点「生成深度报道」时才调用：读原文、搜索背景，写一篇长文。"
        }
    }
}

extension UserConfig {
    func choice(for task: AITask) -> ModelChoice? {
        switch task {
        case .tasks: ai.tasks
        case .brief: ai.brief
        case .report: ai.report
        }
    }

    mutating func setChoice(_ choice: ModelChoice?, for task: AITask) {
        switch task {
        case .tasks: ai.tasks = choice
        case .brief: ai.brief = choice
        case .report: ai.report = choice
        }
    }

    /// 实际会用的服务商和模型（和 Worker 的 resolveChoice 一样：没选就用第一家配了 key 的）
    func resolved(_ task: AITask, providers: [AIProvider]) -> (provider: AIProvider, model: String)? {
        if let choice = choice(for: task), let provider = providers.first(where: { $0.id == choice.provider }) {
            let model = choice.model.trimmingCharacters(in: .whitespaces)
            return (provider, model.isEmpty ? provider.defaults[task.rawValue] ?? "" : model)
        }
        guard let first = providers.first(where: \.configured) else { return nil }
        return (first, first.defaults[task.rawValue] ?? "")
    }

    /// 每份简报大约多少美元：按选的话题估标题数，再按模型价格算（和实际花费可能差一半，只作参考）
    func estimatedBriefUSD(providers: [AIProvider], topics: [NewsTopic]) -> Double? {
        guard let (provider, model) = resolved(.brief, providers: providers),
              let price = provider.models.filter({ model.hasPrefix($0.id) }).max(by: { $0.id.count < $1.id.count }) else { return nil }
        let feeds = min(40, topics.filter { news.topics.contains($0.id) }.map(\.feeds).reduce(0, +) + news.customFeeds.count)
        let headlines = Double(feeds) * 8
        let input = 2_500 + headlines * 70
        let output = 4_500 + Double(news.count) * 380
        let batch = provider.id == "anthropic" ? 0.5 : 1
        return (input * price.input + output * price.output) / 1_000_000 * batch
    }
}

/// 配置里的 id 和时间格式
enum ConfigFormat {
    /// "Sydney" → "sydney"、"São Paulo" → "sao_paulo"（Worker 要求 [a-z0-9_]）
    static func slug(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
        let parts = folded.lowercased().split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        let joined = parts.joined(separator: "_")
        return joined.isEmpty ? "item" : String(joined.prefix(30))
    }

    /// 已经有了就加序号
    static func uniqueID(_ base: String, existing: [String]) -> String {
        let slug = slug(base)
        var id = slug
        var n = 2
        while existing.contains(id) {
            id = "\(slug)_\(n)"
            n += 1
        }
        return id
    }

    /// "07:30" ↔ 今天 7:30（给 DatePicker 用）
    static func date(from hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let components = DateComponents(hour: parts.first ?? 8, minute: parts.count > 1 ? parts[1] : 0)
        return Calendar.current.date(from: components) ?? .now
    }

    static func hhmm(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 8, c.minute ?? 0)
    }
}

/// 设置里几个页面共用：读一次 Worker 的配置，编辑草稿，保存
@MainActor @Observable
final class ConfigStore {
    static let shared = ConfigStore()

    /// Worker 上保存的版本
    private(set) var saved: UserConfig?
    /// 正在编辑的版本
    var draft = UserConfig()
    private(set) var providers: [AIProvider] = []
    private(set) var topics: [NewsTopic] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var error: String?

    var hasChanges: Bool { saved != nil && draft != saved }

    func loadIfNeeded() async {
        if saved == nil { await load() }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            apply(try await DSAClient.fromSettings().config())
            error = nil
        } catch DSAClient.ClientError.http(404, _) {
            error = "Worker 是旧版本，请先在 worker 目录运行 npx wrangler deploy 部署新版"
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save() async {
        isSaving = true
        defer { isSaving = false }
        var config = draft
        // 新闻按这台设备的时区生成
        config.timezone = TimeZone.current.identifier
        do {
            apply(try await DSAClient.fromSettings().saveConfig(config))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func discardChanges() {
        if let saved { draft = saved }
    }

    private func apply(_ response: ConfigResponse) {
        saved = response.config
        draft = response.config
        providers = response.providers
        topics = response.topics
    }
}
