import SwiftUI

/// 点开一条新闻：摘要 + 👍👎 + 深度报道（第一次打开时才生成）+ 原文链接。
/// 点开、看了多久、打开原文、👍👎 都会发给 Worker，用来学习你的兴趣
struct NewsDetailView: View {
    let route: NewsRoute

    @State private var store = NewsStore.shared
    @AppStorage(NewsLanguage.storageKey) private var languageRaw = NewsLanguage.zh.rawValue

    private var lang: NewsLanguage { NewsLanguage(rawValue: languageRaw) ?? .zh }
    private var item: NewsItem { route.item }
    private var key: String { NewsStore.reportKey(date: route.date, id: item.id) }
    @State private var openedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                reportSection
                let sources = (store.report(date: route.date, id: item.id)?.sources ?? []) + item.sources
                if !sources.isEmpty {
                    SourcesCard(sources: sources, lang: lang)
                }
            }
            .padding(16)
        }
        .background { AmbientBackground() }
        .navigationTitle(lang.pick("深度报道", "In depth"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        // 只取已经生成好的报道，不会自动生成（生成要花钱，点按钮才生成）
        .task { store.loadReport(date: route.date, id: item.id) }
        .onAppear {
            openedAt = .now
            store.recordOpen(date: route.date, id: item.id)
        }
        .onDisappear {
            if let openedAt { store.recordRead(date: route.date, id: item.id, seconds: Date.now.timeIntervalSince(openedAt)) }
            openedAt = nil
        }
        // 点原文链接也记一次，然后照常用浏览器打开
        .environment(\.openURL, OpenURLAction { url in
            store.recordLink(date: route.date, id: item.id)
            return .systemAction(url)
        })
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label(item.category.name(lang, names: store.brief?.categories), systemImage: item.category.systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(item.category.tint)
                if let region = item.regionName(lang, names: store.brief?.regions) {
                    Text(region).font(.caption).foregroundStyle(.secondary)
                }
                if item.isExplore {
                    Pill(text: lang.pick("猜你喜欢", "You might like"), tint: .pink)
                }
                if item.affectsMe {
                    Pill(text: lang.pick("与你相关", "For you"), tint: .orange)
                }
                Spacer()
                Text("#\(item.rank) · \(NewsDate.title(route.date, language: lang))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.title(lang))
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.summary(lang))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if item.isExplore, !item.reason(lang).isEmpty {
                Label(item.reason(lang), systemImage: "sparkles")
                    .font(.footnote)
                    .foregroundStyle(.pink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VoteButtons(vote: store.votes[key] ?? 0, lang: lang) { value in
                store.vote(date: route.date, id: item.id, value)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private var reportSection: some View {
        if let report = store.report(date: route.date, id: item.id) {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(report.sections, id: \.self) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.heading(lang)).font(.headline)
                        ForEach(Array(section.paragraphs(lang).enumerated()), id: \.offset) { _, paragraph in
                            Text(Self.inlineMarkdown(paragraph))
                                .font(.body)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .textSelection(.enabled)
            .glassCard(cornerRadius: 26, padding: 18)

            if !report.impact(lang).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(lang.pick("对你的影响", "What it means for you"), systemImage: "scope")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text(Self.inlineMarkdown(report.impact(lang)))
                        .font(.body)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .textSelection(.enabled)
                .glassCard(cornerRadius: 22, padding: 16)
            }

            if let stats = report.stats {
                let cost = stats.priced == false ? "—" : Self.usd(stats.costUSD)
                Text(lang.pick("这篇深度报道花费 \(cost)", "This report cost \(cost)"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        } else if let error = store.reportErrors[key] {
            VStack(alignment: .leading, spacing: 10) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                Button(lang.pick("重试", "Try again")) {
                    store.generateReport(date: route.date, id: item.id)
                }
                .buttonStyle(.glass)
            }
            .glassCard(cornerRadius: 22, padding: 16)
        } else if store.loadingReports.contains(key) {
            HStack(spacing: 14) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text(lang.pick("正在阅读原文、查找背景…", "Reading the sources and digging into the background…"))
                        .font(.subheadline.weight(.semibold))
                    Text(lang.pick("大约需要 30–90 秒。可以离开这个页面，但最好先别切出 DSA", "Takes 30–90 seconds. You can leave this page, but try to stay in DSA"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .glassCard(cornerRadius: 22, padding: 16)
        } else if store.checkingReports.contains(key) {
            // 正在问 Worker 有没有已经生成好的，先不显示按钮，免得一闪而过
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label(lang.pick("深度报道", "In-depth report"), systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Text(lang.pick(
                    "让 Claude 阅读原文、查找背景，写一篇中英双语深度报道和对你的影响。大约 30–90 秒，每篇按次计费。",
                    "Claude reads the sources, looks up the background, and writes a bilingual in-depth report with what it means for you. Takes 30–90 seconds; each report is billed."
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button {
                    store.generateReport(date: route.date, id: item.id)
                } label: {
                    Label(lang.pick("生成深度报道", "Generate report"), systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .glassCard(cornerRadius: 22, padding: 16)
        }
    }

    private static func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(2...3)))
    }

    /// 报道里只用了 **粗体** 这类行内格式
    static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

private struct SourcesCard: View {
    let sources: [NewsSource]
    let lang: NewsLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(lang.pick("原文和参考", "Sources")).font(.headline)
            ForEach(unique, id: \.url) { source in
                if let url = source.link {
                    Link(destination: url) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if let title = source.title, !title.isEmpty {
                                    Text(title)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .glassCard(cornerRadius: 22, padding: 16)
    }

    /// 报道和简报里可能有同一个链接，按链接去重（保留带标题的那条）
    private var unique: [NewsSource] {
        var byURL: [String: NewsSource] = [:]
        var order: [String] = []
        for source in sources {
            if let existing = byURL[source.url] {
                if existing.title == nil { byURL[source.url] = source }
            } else {
                byURL[source.url] = source
                order.append(source.url)
            }
        }
        return order.compactMap { byURL[$0] }
    }
}

// MARK: - 👍👎

/// 喜欢 / 不想看：比自动判断的分量重，第二天起这一类新闻会多推或少推
private struct VoteButtons: View {
    let vote: Int
    let lang: NewsLanguage
    let onVote: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            button(value: 1, symbol: "hand.thumbsup", title: lang.pick("喜欢", "More like this"), tint: .green)
            button(value: -1, symbol: "hand.thumbsdown", title: lang.pick("不想看", "Less like this"), tint: .orange)
        }
        .padding(.top, 2)
    }

    private func button(value: Int, symbol: String, title: String, tint: Color) -> some View {
        let selected = vote == value
        return Button {
            onVote(value)
        } label: {
            Label(title, systemImage: selected ? "\(symbol).fill" : symbol)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(tint.opacity(0.15)) : AnyShapeStyle(.primary.opacity(0.06)), in: .capsule)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
