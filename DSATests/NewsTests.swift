import Foundation
import Testing
@testable import DSA

@Suite("新闻")
struct NewsTests {
    /// 和 Worker 存进 KV 的格式一致（generatedAt 带毫秒）
    static let briefJSON = """
    {"brief":{"date":"2026-10-03","generatedAt":"2026-10-02T20:47:12.345Z",
    "items":[
      {"id":"1","rank":1,"category":"conflict","importance":5,"titleZh":"红海航运再受袭击","titleEn":"Red Sea shipping attacked again",
       "summaryZh":"摘要","summaryEn":"Summary","sources":[{"name":"BBC News","url":"https://www.bbc.com/news/1","title":"Ships attacked"}],"affectsMe":true},
      {"id":"2","rank":2,"category":"space","importance":3,"titleZh":"新分类","titleEn":"","summaryZh":"中文摘要","summaryEn":"",
       "sources":[],"affectsMe":false}
    ],
    "impact":{"overviewZh":"运费可能上涨","overviewEn":"Freight may rise",
      "points":[{"area":"family_business","titleZh":"运费","titleEn":"Freight","detailZh":"绕行好望角","detailEn":"Rerouting","itemRanks":[1]},
                {"area":"something_new","titleZh":"其他","titleEn":"Other","detailZh":"","detailEn":"","itemRanks":[]}]},
    "weather":[{"city":"london","nameZh":"伦敦","nameEn":"London","extreme":true,"noteZh":"雷暴","noteEn":"Storms",
      "days":[{"date":"2026-10-03","code":95,"max":22.1,"min":16.7,"precip":20.3,"gust":54.7}]}],
    "fx":[{"pair":"EUR/CNY","rate":7.5259,"change7d":-1.69},{"pair":"AUD/USD","rate":0.6939,"change7d":null}],
    "stats":{"feeds":26,"failedFeeds":["RBA"],"headlines":207,"costUSD":0.1432}}}
    """

    struct Wrapper: Decodable { var brief: NewsBrief }

    @Test func decodesWorkerBrief() throws {
        let brief = try DSAClient.decoder.decode(Wrapper.self, from: Data(Self.briefJSON.utf8)).brief
        #expect(brief.date == "2026-10-03")
        #expect(brief.items.count == 2)
        #expect(brief.items[0].category == NewsCategory("conflict"))
        #expect(brief.items[0].category.name(.zh) == "战争冲突")
        // 不认识的分类、影响领域不让整份简报解析失败，直接显示 id
        #expect(brief.items[1].category.id == "space")
        #expect(brief.items[1].category.name(.en) == "Space")
        #expect(brief.items[1].category.systemImage == "newspaper")
        // 以前的简报没有 interests，用 id 显示
        #expect(brief.interests == nil)
        #expect(brief.impact.points[0].area.name(.zh, names: brief.interests) == "Family Business")
        #expect(brief.impact.points[1].area.id == "something_new")
        #expect(brief.weather.first?.extreme == true)
        #expect(brief.fx[1].change7d == nil)
        #expect(brief.stats?.failedFeeds == ["RBA"])
    }

    @Test func cacheRoundTripKeepsEverything() throws {
        let brief = try DSAClient.decoder.decode(Wrapper.self, from: Data(Self.briefJSON.utf8)).brief
        let data = try DSAClient.encoder.encode(brief)
        let again = try DSAClient.decoder.decode(NewsBrief.self, from: data)
        #expect(again.items == brief.items)
        #expect(again.impact == brief.impact)
        #expect(abs(again.generatedAt.timeIntervalSince(brief.generatedAt)) < 1)
    }

    @Test func languageFallsBackWhenOneSideIsEmpty() throws {
        let brief = try DSAClient.decoder.decode(Wrapper.self, from: Data(Self.briefJSON.utf8)).brief
        let item = brief.items[1]
        #expect(item.title(.zh) == "新分类")
        #expect(item.title(.en) == "新分类")
        #expect(brief.items[0].title(.en) == "Red Sea shipping attacked again")
    }

    /// 新版 Worker 的简报带 interests（影响各方面的名字）和 priced
    @Test func usesInterestNamesFromBrief() throws {
        var json = Self.briefJSON
        json = json.replacingOccurrences(of: #""stats":{"feeds":26"#, with: #""interests":{"family_business":{"nameZh":"家里生意","nameEn":"Family business"}},"stats":{"priced":false,"feeds":26"#)
        let brief = try DSAClient.decoder.decode(Wrapper.self, from: Data(json.utf8)).brief
        let area = brief.impact.points[0].area
        #expect(area.name(.zh, names: brief.interests) == "家里生意")
        #expect(area.name(.en, names: brief.interests) == "Family business")
        #expect(ImpactArea("markets").name(.zh, names: nil) == "市场")
        #expect(brief.stats?.priced == false)
        // 存进本地缓存再读出来，分类和名字都还在（时间的毫秒会丢，不比）
        let again = try DSAClient.decoder.decode(NewsBrief.self, from: DSAClient.encoder.encode(brief))
        #expect(again.items == brief.items)
        #expect(again.impact == brief.impact)
        #expect(again.interests == brief.interests)
        #expect(again.stats == brief.stats)
    }

    struct ReportWrapper: Decodable { var report: NewsReport }

    /// 以前生成的报道没有 stats，新的带 stats（App 只用 costUSD，其他用量字段忽略）
    @Test func decodesReportWithAndWithoutStats() throws {
        let base = """
        "titleZh":"标题","titleEn":"Title","sections":[{"headingZh":"发生了什么","headingEn":"What happened","bodyZh":"正文","bodyEn":"Body"}],
        "impactZh":"影响","impactEn":"Impact","sources":[{"name":"BBC","url":"https://bbc.com/1"}],"generatedAt":"2026-10-04T01:02:03.456Z"
        """
        let old = try DSAClient.decoder.decode(ReportWrapper.self, from: Data("{\"report\":{\(base)}}".utf8)).report
        #expect(old.stats == nil)

        let stats = #","stats":{"costUSD":0.0712,"inputTokens":4210,"cacheWriteTokens":21033,"cacheReadTokens":88120,"outputTokens":3902,"searches":2,"fetches":3,"turns":1}"#
        let new = try DSAClient.decoder.decode(ReportWrapper.self, from: Data("{\"report\":{\(base)\(stats)}}".utf8)).report
        #expect(new.stats?.costUSD == 0.0712)
        #expect(new.sections.count == 1)

        // 存进本地缓存再读出来，花费还在
        let again = try DSAClient.decoder.decode(NewsReport.self, from: DSAClient.encoder.encode(new))
        #expect(again.stats == new.stats)
    }

    /// 旧版 Worker 没有 todayPending
    @Test func decodesTodayPending() throws {
        let old = try DSAClient.decoder.decode(DSAClient.NewsDates.self, from: Data(#"{"today":"2026-10-07","dates":["2026-10-06"],"monthCostUSD":2.53}"#.utf8))
        #expect(old.todayPending == nil)
        let new = try DSAClient.decoder.decode(DSAClient.NewsDates.self, from: Data(#"{"today":"2026-10-07","dates":[],"monthCostUSD":2.6,"todayPending":true}"#.utf8))
        #expect(new.todayPending == true)
    }

    @Test func reportParagraphsSplitOnBlankLines() {
        let section = NewsReport.Section(headingZh: "发生了什么", headingEn: "What happened", bodyZh: "第一段。\n\n  第二段 **重点**。\n\n\n", bodyEn: "")
        #expect(section.paragraphs(.zh) == ["第一段。", "第二段 **重点**。"])
        #expect(section.paragraphs(.en) == ["第一段。", "第二段 **重点**。"])
    }

    @Test(arguments: [(0, "sun.max.fill"), (2, "cloud.sun.fill"), (63, "cloud.rain.fill"), (65, "cloud.heavyrain.fill"), (75, "cloud.snow.fill"), (95, "cloud.bolt.rain.fill"), (123, "cloud.fill")])
    func weatherSymbols(code: Int, symbol: String) {
        #expect(CityWeather.symbol(for: code) == symbol)
    }

    @Test func dateTitles() {
        #expect(NewsDate.title("2026-10-03", language: .zh).contains("10月3日"))
        #expect(NewsDate.title("not a date", language: .zh) == "not a date")
    }
}
