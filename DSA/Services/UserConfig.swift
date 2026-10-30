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
    /// 可选的兴趣
    var topics: [NewsTopic]
    /// 兴趣的大类（旧版 Worker 没有）
    var groups: [NewsTopicGroup]?
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

/// 一个兴趣（Worker 的 topics.ts）
struct NewsTopic: Decodable, Identifiable, Sendable {
    var id: String
    var nameZh: String
    var nameEn: String
    /// 大类 id（旧版 Worker 没有）
    var group: String?
    /// 这个兴趣有几个新闻源
    var feeds: Int
}

struct NewsTopicGroup: Decodable, Identifiable, Sendable {
    var id: String
    var nameZh: String
    var nameEn: String
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
        case .tasks: "分析邮件、商家分类、识别小票。用量大，适合便宜、能看图的小模型。"
        case .brief: "每天一次，挑新闻、写双语简报。Claude 用批处理半价。"
        case .report: "点「生成深度报道」时才用：读原文、搜背景、写长文。"
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

    /// 每份简报大约多少美元：按选的兴趣估标题数（加上常看地区和猜你喜欢的几个源），再按模型价格算（和实际花费可能差一半，只作参考）
    func estimatedBriefUSD(providers: [AIProvider], topics: [NewsTopic]) -> Double? {
        guard let (provider, model) = resolved(.brief, providers: providers),
              let price = provider.models.filter({ model.hasPrefix($0.id) }).max(by: { $0.id.count < $1.id.count }) else { return nil }
        let feeds = min(40, topics.filter { news.topics.contains($0.id) }.map(\.feeds).reduce(0, +) + news.customFeeds.count + 8)
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
    private(set) var groups: [NewsTopicGroup] = []
    private(set) var isLoading = false
    private(set) var isSaving = false
    var error: String?

    var hasChanges: Bool { saved != nil && draft != saved }
    private var loadedAt = Date.distantPast

    /// 还没读过就读；读过超过 5 分钟、又没有没保存的修改时也重新读，别的设备改过的设置这里也能看到
    func loadIfNeeded() async {
        if saved == nil || (!hasChanges && Date.now.timeIntervalSince(loadedAt) > 5 * 60) { await load() }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let before = draft
        do {
            let response = try await DSAClient.fromSettings().config()
            let edited = draft
            apply(response)
            // 读的这一会儿用户又改了：保留这些改动，别被刚读到的覆盖掉
            if edited != before, let merged = try? UserConfig.merge(local: edited, base: before, remote: response.config) {
                draft = merged
            }
            error = nil
            // Worker 默认按 UTC 算简报时间；时区和这台设备不一样时保存一次（保存时会带上设备时区）
            if response.config.timezone != TimeZone.current.identifier { await save() }
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
        // 这台读到的版本。要在发请求之前记下：等回复的时候 load() 可能已经换掉了 saved
        let base = saved
        do {
            let client = try DSAClient.fromSettings()
            do {
                apply(try await client.saveConfig(config, base: base?.updatedAt))
            } catch DSAClient.ClientError.http(409, _) {
                // 这台读到配置以后别的设备又存过：拿最新的，合并上这台改的再存，不然会把那边的改动冲掉
                let latest = try await client.config().config
                // KV 刚写完的一小会儿可能还读到旧的；比这台读到的还旧就不能拿来合并
                guard let base, latest.updatedAt >= base.updatedAt else {
                    error = "设置刚在别的设备上改过，保存失败，请稍后再试"
                    return
                }
                var merged = try UserConfig.merge(local: config, base: base, remote: latest)
                merged.timezone = TimeZone.current.identifier
                apply(try await client.saveConfig(merged, base: latest.updatedAt))
            }
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
        groups = response.groups ?? []
        loadedAt = .now
    }
}

extension UserConfig {
    /// 三方合并：这台改过的字段（和它读到的 base 不一样）用这台的，没改过的用 Worker 上最新的 remote。
    /// 按 JSON 合并，以后加字段不用改这里。news、ai 里逐项合并；列表、文字整项替换，
    /// ai 里的每一组（服务商 + 模型）也整组替换，不然会拼出「OpenAI + Claude 的模型」
    static func merge(local: UserConfig, base: UserConfig, remote: UserConfig) throws -> UserConfig {
        func object(_ config: UserConfig) throws -> Any { try JSONSerialization.jsonObject(with: JSONEncoder().encode(config)) }
        func mergeValue(_ local: Any?, _ base: Any?, _ remote: Any?, path: [String]) -> Any? {
            // 只往下合并两层：顶层和 news、ai。再往下（ai.tasks 这种）整个当一个值
            if path.count < 2, let local = local as? [String: Any], let remote = remote as? [String: Any] {
                let base = base as? [String: Any] ?? [:]
                var result = remote
                // 没值的可选字段编码时会省掉，所以也要看 base 里有、这台删掉了的
                for key in Set(local.keys).union(base.keys) {
                    result[key] = mergeValue(local[key], base[key], remote[key], path: path + [key])
                }
                return result
            }
            let unchanged = (local as? NSObject)?.isEqual(base) ?? (base == nil)
            return unchanged ? remote : local
        }
        let merged = mergeValue(try object(local), try object(base), try object(remote), path: []) ?? [:]
        var config = try JSONDecoder().decode(UserConfig.self, from: JSONSerialization.data(withJSONObject: merged))
        // 下次保存时 Worker 按这个判断有没有又被别的设备改过
        config.updatedAt = remote.updatedAt
        return config
    }
}
