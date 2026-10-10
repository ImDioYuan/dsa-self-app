import SwiftUI

/// 「新闻」页：对我的影响、关注城市的天气、汇率、今日要闻
struct NewsView: View {
    @State private var store = NewsStore.shared
    @AppStorage(NewsLanguage.storageKey) private var languageRaw = NewsLanguage.zh.rawValue
    @State private var showingInterests = false

    private var lang: NewsLanguage { NewsLanguage(rawValue: languageRaw) ?? .zh }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let brief = store.brief {
                        if store.todayMissing {
                            TodayMissingCard(store: store, showingDate: brief.date, lang: lang)
                        }
                        if let error = store.error {
                            NewsErrorCard(message: error)
                        }
                        ImpactCard(impact: brief.impact, names: brief.interests, date: brief.date, items: brief.items, lang: lang)
                        if !brief.weather.isEmpty {
                            WeatherRow(weather: brief.weather, lang: lang)
                        }
                        if !brief.fx.isEmpty {
                            FXCard(rates: brief.fx, lang: lang)
                        }
                        NewsSectionTitle(text: lang.pick("今日要闻", "Top stories"), count: brief.items.count)
                            .padding(.top, 8)
                        ForEach(brief.items) { item in
                            NavigationLink(value: NewsRoute(date: brief.date, item: item)) {
                                NewsRow(item: item, brief: brief, lang: lang)
                            }
                            .buttonStyle(.plain)
                        }
                        BriefFooter(brief: brief, monthCostUSD: store.monthCostUSD, lang: lang)
                    } else {
                        EmptyNewsCard(store: store, lang: lang)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background { AmbientBackground() }
            .navigationTitle(lang.pick("新闻", "News"))
            .navigationDestination(for: NewsRoute.self) { route in
                NewsDetailView(route: route)
            }
            .sheet(isPresented: $showingInterests) {
                NavigationStack {
                    InterestsView(showsDoneButton: true)
                }
                .macSheetFrame(minWidth: 460, minHeight: 560)
                .themedTint()
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    NewsLanguagePicker(selection: $languageRaw)
                    Button {
                        showingInterests = true
                    } label: {
                        Label(lang.pick("我的兴趣", "My interests"), systemImage: "slider.horizontal.3")
                    }
                    if !store.dates.isEmpty {
                        Menu {
                            ForEach(store.dates, id: \.self) { date in
                                Button {
                                    store.select(date: date)
                                } label: {
                                    if date == store.brief?.date {
                                        Label(NewsDate.title(date, language: lang), systemImage: "checkmark")
                                    } else {
                                        Text(NewsDate.title(date, language: lang))
                                    }
                                }
                            }
                        } label: {
                            Label(lang.pick("往期", "Past briefs"), systemImage: "calendar")
                        }
                    }
                }
            }
            .refreshable { await store.refresh() }
            .task { store.refreshIfStale() }
        }
    }
}

// MARK: - 中 / EN 切换

/// 不用系统的分段控件：它自带一层玻璃底，放进工具栏会和工具栏的玻璃胶囊叠成两圈。
/// 这里只画选中的那一小块，外面的玻璃交给工具栏
struct NewsLanguagePicker: View {
    @Binding var selection: String
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NewsLanguage.allCases, id: \.self) { language in
                let selected = selection == language.rawValue
                Button {
                    // 不包 withAnimation：整页 20 多张玻璃卡片一起做换行动画会很卡，只让选中块滑过去
                    selection = language.rawValue
                } label: {
                    Text(language == .zh ? "中" : "EN")
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? .primary : .secondary)
                        .frame(width: 38, height: 30)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(.primary.opacity(0.1))
                                    .matchedGeometryEffect(id: "thumb", in: thumb)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .animation(.snappy, value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("语言")
    }
}

// MARK: - 对我的影响

private struct ImpactCard: View {
    let impact: NewsImpact
    let names: [String: LocalizedName]?
    let date: String
    let items: [NewsItem]
    let lang: NewsLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(lang.pick("对你的影响", "What it means for you"), systemImage: "scope")
                        .font(.headline)
                    Spacer()
                    Text(NewsDate.title(date, language: lang))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(impact.overview(lang))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(impact.points.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: point.area.systemImage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(point.area.tint)
                        .frame(width: 30, height: 30)
                        .background(point.area.tint.opacity(0.15), in: .circle)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(point.title(lang))
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 8)
                            Text(point.area.name(lang, names: names))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(point.area.tint)
                        }
                        Text(point.detail(lang))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        RelatedLinks(ranks: point.itemRanks, items: items, date: date)
                    }
                }
            }
        }
        .glassCard(cornerRadius: 26, padding: 18)
    }
}

/// 「#2  #5」：点一下跳到相关新闻
private struct RelatedLinks: View {
    let ranks: [Int]
    let items: [NewsItem]
    let date: String

    var body: some View {
        let related = ranks.compactMap { rank in items.first { $0.rank == rank } }
        if !related.isEmpty {
            HStack(spacing: 6) {
                ForEach(related) { item in
                    NavigationLink(value: NewsRoute(date: date, item: item)) {
                        Text("#\(item.rank)")
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.12), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
            .padding(.top, 2)
        }
    }
}

// MARK: - 天气

private struct WeatherRow: View {
    let weather: [CityWeather]
    let lang: NewsLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(weather) { city in
                WeatherCard(city: city, lang: lang)
            }
        }
    }
}

private struct WeatherCard: View {
    let city: CityWeather
    let lang: NewsLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(city.name(lang)).font(.subheadline.weight(.semibold))
                Spacer()
                if city.extreme {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let today = city.days.first {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: CityWeather.symbol(for: today.code))
                        .symbolRenderingMode(.multicolor)
                        .font(.title2)
                    Text("\(Int(today.max.rounded()))°")
                        .font(.title2.weight(.semibold))
                    Text("\(Int(today.min.rounded()))°")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Text(city.note(lang))
                .font(.caption)
                .foregroundStyle(city.extreme ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassCard(cornerRadius: 22, padding: 14)
    }
}

// MARK: - 汇率

private struct FXCard: View {
    let rates: [FXRate]
    let lang: NewsLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(lang.pick("汇率 · 近一周", "FX · past week"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 8) {
                ForEach(rates, id: \.pair) { rate in
                    HStack(spacing: 6) {
                        Text(rate.pair).font(.caption).foregroundStyle(.secondary)
                        Text(rate.rate, format: .number.precision(.fractionLength(4)))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                        if let change = rate.change7d {
                            Text("\(change >= 0 ? "▲" : "▼")\(abs(change), format: .number.precision(.fractionLength(1)))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(change >= 0 ? Color.green : Color.red)
                        }
                    }
                }
            }
        }
        .glassCard(cornerRadius: 22, padding: 14)
    }
}

// MARK: - 新闻行

private struct NewsRow: View {
    let item: NewsItem
    let brief: NewsBrief
    let lang: NewsLanguage

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(item.rank)")
                .font(.system(.title3, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(item.rank <= 3 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(minWidth: 26, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(item.category.name(lang, names: brief.categories), systemImage: item.category.systemImage)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(item.category.tint)
                    if let region = item.regionName(lang, names: brief.regions) {
                        Text(region).font(.caption).foregroundStyle(.secondary)
                    }
                    if item.isExplore {
                        Pill(text: lang.pick("猜你喜欢", "You might like"), tint: .pink)
                    }
                    if item.importance >= 5 {
                        Pill(text: lang.pick("重大", "Major"), tint: .red)
                    }
                    if item.affectsMe {
                        Pill(text: lang.pick("与你相关", "For you"), tint: .orange)
                    }
                }
                Text(item.title(lang))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(item.summary(lang))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                if item.isExplore, !item.reason(lang).isEmpty {
                    Label(item.reason(lang), systemImage: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.pink)
                        .lineLimit(2)
                }
                if !item.sources.isEmpty {
                    Text(item.sources.map(\.name).uniqued().joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .glassCard(cornerRadius: 22, padding: 16)
        .contentShape(.rect(cornerRadius: 22))
    }
}

// MARK: - 状态卡片

private struct TodayMissingCard: View {
    let store: NewsStore
    let showingDate: String
    let lang: NewsLanguage

    private var beforeEight: Bool { Calendar.current.component(.hour, from: .now) < 8 }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: store.isGenerating || store.todayPending ? "hourglass" : "clock")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if store.isGenerating {
                ProgressView()
            } else {
                Button(lang.pick("立即生成", "Generate")) {
                    Task { await store.generateToday() }
                }
                .buttonStyle(.glass)
            }
        }
        .glassCard(cornerRadius: 22, padding: 14)
    }

    private var title: String {
        if store.isGenerating { return lang.pick("正在生成今天的简报…", "Generating today's brief…") }
        if store.todayPending { return lang.pick("今天的简报排队生成中（半价）", "Today's brief is queued (half price)") }
        return beforeEight
            ? lang.pick("今天的简报 8:00 前送到", "Today's brief arrives by 8:00")
            : lang.pick("今天的简报还没生成", "Today's brief isn't ready")
    }

    private var subtitle: String {
        if store.isGenerating { return lang.pick("大约需要 1–2 分钟", "Takes about 1–2 minutes") }
        if store.todayPending { return lang.pick("一般几分钟内送到，下拉刷新看看", "Usually ready within minutes — pull to refresh") }
        return lang.pick("现在显示的是 ", "Showing ") + NewsDate.title(showingDate, language: lang)
    }
}

private struct EmptyNewsCard: View {
    let store: NewsStore
    let lang: NewsLanguage

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "newspaper")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            if store.isLoading {
                ProgressView()
            } else if store.isGenerating {
                ProgressView()
                Text(lang.pick("正在抓取新闻、写简报，大约 1–2 分钟", "Reading the news and writing your brief, about 1–2 minutes"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text(lang.pick("还没有新闻简报", "No briefs yet")).font(.headline)
                Text(lang.pick(
                    "每天早上自动生成：要闻、对你的影响、关注城市的天气。兴趣在右上角的「我的兴趣」里选，条数、城市和时间在 设置 → 新闻 里调整。也可以现在生成一份。",
                    "A brief arrives every morning: top stories, what they mean for you, and the weather where you care. Change topics, count, cities and time in Settings → News."
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                if let error = store.error {
                    Text(error).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                }
                Button(lang.pick("立即生成", "Generate now")) {
                    Task { await store.generateToday() }
                }
                .buttonStyle(.glass)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 24, padding: 22)
        .padding(.top, 8)
    }
}

private struct NewsErrorCard: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.orange)
            .glassCard(cornerRadius: 18, padding: 12)
    }
}

private struct NewsSectionTitle: View {
    let text: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(text).font(.title3.weight(.semibold))
            Text("\(count)").font(.title3).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

private struct BriefFooter: View {
    let brief: NewsBrief
    let monthCostUSD: Double?
    let lang: NewsLanguage

    var body: some View {
        VStack(spacing: 4) {
            Text(generated)
            if let stats = brief.stats {
                Text(lang.pick(
                    "\(stats.feeds) 个新闻源 · \(stats.headlines) 条标题 · 这份 \(cost(stats))",
                    "\(stats.feeds) sources · \(stats.headlines) headlines · this brief \(cost(stats))"
                ))
            }
            if let monthCostUSD {
                Text(lang.pick("本月新闻花费 \(usd(monthCostUSD))", "News cost this month \(usd(monthCostUSD))"))
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var generated: String {
        let time = brief.generatedAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(Locale(identifier: "en_GB")))
        return lang.pick("\(NewsDate.title(brief.date, language: lang)) \(time) 生成", "Generated \(time), \(NewsDate.title(brief.date, language: lang))")
    }

    private func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    /// 模型不在 Worker 的价格表里时算不出花费
    private func cost(_ stats: NewsBrief.Stats) -> String {
        stats.priced == false ? "—" : usd(stats.costUSD)
    }
}

extension Sequence where Element: Hashable {
    /// 去重，保留第一次出现的顺序
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
