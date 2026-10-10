import Foundation
import SwiftData
import Testing
@testable import DSA

@Suite("设置和配置", .serialized)
struct SettingsTests {
    // MARK: 订阅日历

    /// 旧版只有一个 Moodle 链接：第一次读取时迁移成一条叫「Moodle」的订阅
    @Test func migratesOldMoodleLink() {
        let defaults = UserDefaults.standard
        let savedFeeds = defaults.data(forKey: SettingsKey.icalFeeds)
        let savedOld = defaults.string(forKey: SettingsKey.moodleICalURL)
        defer {
            defaults.set(savedFeeds, forKey: SettingsKey.icalFeeds)
            defaults.set(savedOld, forKey: SettingsKey.moodleICalURL)
        }

        defaults.removeObject(forKey: SettingsKey.icalFeeds)
        defaults.set(" webcal://example.edu/calendar/export.ics?token=abc ", forKey: SettingsKey.moodleICalURL)
        let feeds = AppSettings.icalFeeds
        #expect(feeds.map(\.name) == ["Moodle"])
        #expect(feeds.first?.downloadURL?.absoluteString == "https://example.edu/calendar/export.ics?token=abc")
        #expect(defaults.string(forKey: SettingsKey.moodleICalURL) == nil)

        // 只迁移一次；以后改了就按新的
        AppSettings.icalFeeds = []
        #expect(AppSettings.icalFeeds.isEmpty)
    }

    @Test func icalLinkSchemes() {
        #expect(ICalFeed(name: "", url: "WEBCAL://a.example/x.ics").downloadURL?.scheme == "https")
        #expect(ICalFeed(name: "", url: "https://a.example/x.ics").downloadURL?.absoluteString == "https://a.example/x.ics")
    }

    /// 任务上显示订阅日历的名字；没有名字就显示来源类型
    @MainActor
    @Test func taskShowsFeedName() throws {
        let item = TaskItem(draft: TaskDraft(sourceID: "moodle:1", title: "Quiz", source: .ical, kind: .deadline, importance: .important, sourceLabel: "Moodle"))
        #expect(item.sourceName == "Moodle")
        item.apply(TaskDraft(sourceID: "moodle:1", title: "Quiz", source: .ical, kind: .deadline, importance: .important))
        #expect(item.sourceName == "订阅日历")
        // 旧数据的 raw value 还是 moodle
        #expect(TaskSource(rawValue: "moodle") == .ical)
    }

    // MARK: Gmail

    @Test func gmailQueriesFollowSettings() {
        let plain = GmailSource.defaultQueries(forwardedLabel: nil, extraQuery: nil)
        #expect(plain.count == 1)
        #expect(plain[0].source == .gmail)

        let full = GmailSource.defaultQueries(forwardedLabel: "School Mail", extraQuery: "acme (offer OR interview)")
        #expect(full.map(\.query) == [
            plain[0].query,
            "newer_than:3d (acme (offer OR interview))",
            "label:School-Mail newer_than:3d",
        ])
        #expect(full.last?.source == .outlook)
    }

    // MARK: Worker 配置

    static let configJSON = """
    {"config":{"name":"Alex","about":"student","timezone":"Europe/London","watchRules":[],
      "news":{"topics":["tech_ai","science"],"customFeeds":[],"count":20,
        "places":[{"id":"london","nameZh":"伦敦","nameEn":"London","lat":51.51,"lon":-0.13,"country":"GB","admin1":"England"}],
        "fxPairs":["GBP/EUR"],"interests":[{"id":"career","nameZh":"工作","nameEn":"Career","hint":""}],"briefTime":"07:30"},
      "ai":{"tasks":null,"brief":{"provider":"openai","model":""},"report":null},"updatedAt":""},
     "providers":[
       {"id":"anthropic","name":"Claude","keyName":"ANTHROPIC_API_KEY","configured":true,"webSearch":true,
        "defaults":{"tasks":"claude-haiku-5-5","brief":"claude-sonnet-5-5","report":"claude-sonnet-5-5"},
        "models":[{"id":"claude-sonnet-5-5","input":2,"output":10,"vision":true}]},
       {"id":"openai","name":"OpenAI","keyName":"OPENAI_API_KEY","configured":false,"webSearch":true,
        "defaults":{"tasks":"gpt-6-luna","brief":"gpt-6.1-sol","report":"gpt-6.1-sol"},
        "models":[{"id":"gpt-6.1-sol","input":2,"output":10,"vision":true}]}],
     "topics":[{"id":"tech_ai","nameZh":"科技 AI","nameEn":"Tech & AI","feeds":6},{"id":"science","nameZh":"科学","nameEn":"Science","feeds":3}]}
    """

    @Test func decodesConfigAndResolvesModels() throws {
        let response = try DSAClient.decoder.decode(ConfigResponse.self, from: Data(Self.configJSON.utf8))
        var config = response.config
        #expect(config.news.places.first?.id == "london")
        #expect(config.ai.tasks == nil)

        // 选了 OpenAI 但没填模型 → 用它的默认模型
        #expect(config.resolved(.brief, providers: response.providers)?.model == "gpt-6.1-sol")
        // 没选 → 第一家配了 key 的
        #expect(config.resolved(.tasks, providers: response.providers)?.provider.id == "anthropic")
        #expect(config.resolved(.tasks, providers: response.providers)?.model == "claude-haiku-5-5")

        // Claude 生成简报用批处理，估算是同样用量的一半
        let openai = try #require(config.estimatedBriefUSD(providers: response.providers, topics: response.topics))
        config.setChoice(.init(provider: "anthropic", model: "claude-sonnet-5-5"), for: .brief)
        let claude = try #require(config.estimatedBriefUSD(providers: response.providers, topics: response.topics))
        #expect(abs(claude * 2 - openai) < 0.000001)
    }

    /// 没选模型的组不写进 JSON，Worker 当成 null
    @Test func encodesConfigForWorker() throws {
        var config = UserConfig()
        config.ai.report = .init(provider: "gemini", model: "")
        let json = try #require(String(data: DSAClient.encoder.encode(config), encoding: .utf8))
        #expect(json.contains(#""report":{"#))
        #expect(!json.contains(#""tasks""#))
    }

    @Test func slugsForIDs() {
        #expect(ConfigFormat.slug("New York") == "new_york")
        #expect(ConfigFormat.slug("São Paulo") == "sao_paulo")
        #expect(ConfigFormat.slug("北京") == "item")
        #expect(ConfigFormat.uniqueID("Sydney", existing: ["sydney"]) == "sydney_2")
        #expect(ConfigFormat.hhmm(ConfigFormat.date(from: "07:05")) == "07:05")
    }
}
