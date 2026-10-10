import SwiftUI

/// 我的兴趣：每个兴趣一条可以拖的长条，长条越长明天这个兴趣的新闻越多。
/// AI 每天根据阅读情况自动调（常看的慢慢变长，一直不看的每天变短一点，降到 0 就不推）；你拖过之后从拖的位置接着调。
/// 下面是「猜你喜欢」里发现的兴趣和你常看的地区。兴趣选在配置里（ConfigStore），分数存在 Worker 的 prefs 里
struct InterestsView: View {
    /// 从新闻页弹出来时显示「完成」
    var showsDoneButton = false

    @State private var config = ConfigStore.shared
    @State private var prefs: NewsPrefs?
    /// 正在拖、还没保存的分数
    @State private var levels: [String: Double] = [:]
    @State private var error: String?
    @State private var addingInterests = false
    @Environment(\.dismiss) private var dismiss

    private var topics: [String] { config.saved?.news.topics ?? [] }

    var body: some View {
        Form {
            if let message = error ?? (config.saved == nil ? config.error : nil) {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button("重试") { Task { await load() } }
                }
            }
            if config.saved != nil {
                interestsSection
                suggestionsSection
                regionsSection
            } else if config.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("我的兴趣")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addingInterests = true
                } label: {
                    Label("添加兴趣", systemImage: "plus")
                }
                .disabled(config.saved == nil)
            }
            if showsDoneButton {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $addingInterests, onDismiss: { Task { await saveTopics() } }) {
            InterestCatalogSheet()
        }
        .task { await load() }
    }

    // MARK: - 兴趣长条

    private var counts: [String: Int] {
        InterestAllocation.allocate(topics.map { ($0, level(of: $0)) }, total: config.saved?.news.count ?? 20, exploreSlots: prefs?.exploreCount ?? 2)
    }

    private func level(of id: String) -> Double {
        levels[id] ?? prefs?.interests.first { $0.id == id }?.level ?? InterestAllocation.defaultLevel
    }

    private var interestsSection: some View {
        Section {
            let counts = counts
            ForEach(topics, id: \.self) { id in
                InterestRow(
                    category: NewsCategory(id),
                    name: name(of: id),
                    level: Binding(get: { level(of: id) }, set: { levels[id] = $0 }),
                    previous: prefs?.interests.first { $0.id == id }?.previous,
                    count: counts[id] ?? 0,
                    onCommit: { Task { await saveLevel(id) } }
                )
            }
            .onDelete { offsets in
                // 至少留一个
                guard topics.count > offsets.count else { return }
                config.discardChanges()
                config.draft.news.topics.remove(atOffsets: offsets)
                Task { await saveTopics() }
            }
        } header: {
            Text("我的兴趣")
        } footer: {
            Text("长条越长，明天这个兴趣的新闻越多。AI 每天根据你点开了哪些新闻、看了多久、有没有 👍👎 自动调整：常看的慢慢变长，一直不看的每天变短一点，降到 0 就不再推。你也可以自己拖，左滑删除。另外每天有 \(prefs?.exploreCount ?? 2) 条「猜你喜欢」。")
        }
    }

    // MARK: - 发现

    @ViewBuilder private var suggestionsSection: some View {
        if let suggestions = prefs?.suggestions, !suggestions.isEmpty {
            Section {
                ForEach(suggestions) { suggestion in
                    HStack {
                        Label(suggestion.nameZh, systemImage: NewsCategory(suggestion.id).systemImage)
                            .foregroundStyle(NewsCategory(suggestion.id).tint)
                        Spacer()
                        Button("不感兴趣") { Task { await dismissSuggestion(suggestion.id) } }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        Button("加入") { Task { await add(suggestion.id) } }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("发现")
            } footer: {
                Text("「猜你喜欢」里你常点开的领域，加入后每天都会推。")
            }
        }
    }

    // MARK: - 常看的地区

    @ViewBuilder private var regionsSection: some View {
        if let regions = prefs?.regions, !regions.isEmpty {
            Section {
                ForEach(regions) { region in
                    HStack(spacing: 12) {
                        Text(region.nameZh)
                            .frame(minWidth: 56, alignment: .leading)
                        ProgressView(value: region.share)
                            .tint(.teal)
                        Text(region.share, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                }
            } header: {
                Text("你常看的地区")
            } footer: {
                Text("根据你读过的新闻统计。同样重要的新闻，简报会优先选这些地区的。")
            }
        }
    }

    // MARK: - 读写

    private func name(of id: String) -> String {
        config.topics.first { $0.id == id }?.nameZh ?? NewsCategory(id).name(.zh)
    }

    private func load() async {
        await config.loadIfNeeded()
        guard config.saved != nil, let client = try? DSAClient.fromSettings() else { return }
        do {
            prefs = try await client.newsPrefs()
            levels = [:]
            error = nil
        } catch DSAClient.ClientError.http(404, _) {
            error = "Worker 是旧版本，请先在 worker 目录运行 npx wrangler deploy 部署新版"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveLevel(_ id: String) async {
        guard let value = levels[id], let client = try? DSAClient.fromSettings() else { return }
        do {
            prefs = try await client.updateNewsPrefs(.init(levels: [id: Int(value.rounded())]))
            levels[id] = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 兴趣选在配置里：保存配置，再重新读分数（明天几条会变）
    private func saveTopics() async {
        guard config.hasChanges else { return }
        await config.save()
        await load()
    }

    private func add(_ id: String) async {
        config.discardChanges()
        if !config.draft.news.topics.contains(id) { config.draft.news.topics.append(id) }
        await saveTopics()
    }

    private func dismissSuggestion(_ id: String) async {
        guard let client = try? DSAClient.fromSettings() else { return }
        prefs = try? await client.updateNewsPrefs(.init(dismiss: id))
    }
}

// MARK: - 一个兴趣的长条

private struct InterestRow: View {
    let category: NewsCategory
    let name: String
    @Binding var level: Double
    let previous: Double?
    let count: Int
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(name, systemImage: category.systemImage)
                    .foregroundStyle(category.tint)
                trend
                Spacer()
                Text(count == 0 ? "暂不推" : "明天约 \(count) 条")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            // 不设 step：设了 iOS 会在长条下面画一排刻度
            Slider(value: $level, in: 0...100) {
                Text(name)
            } onEditingChanged: { editing in
                if !editing { onCommit() }
            }
            .tint(category.tint)
        }
        .padding(.vertical, 2)
    }

    /// 和上一次 AI 打分前比，涨了还是降了
    @ViewBuilder private var trend: some View {
        if let previous {
            let change = level - previous
            if change >= 1 {
                Image(systemName: "arrow.up.right").font(.caption2.weight(.bold)).foregroundStyle(.green)
            } else if change <= -1 {
                Image(systemName: "arrow.down.right").font(.caption2.weight(.bold)).foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - 添加兴趣：按大类分组的目录

private struct InterestCatalogSheet: View {
    @State private var config = ConfigStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                ForEach(groups, id: \.id) { group in
                    Section(group.name) {
                        ForEach(config.topics.filter { ($0.group ?? "other") == group.id }) { topic in
                            Toggle(isOn: selected(topic.id)) {
                                HStack {
                                    Label(topic.nameZh, systemImage: NewsCategory(topic.id).systemImage)
                                    Spacer()
                                    Text("\(topic.feeds) 个源").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("添加兴趣")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .macSheetFrame(minWidth: 420, minHeight: 560)
        .themedTint()
    }

    /// 旧版 Worker 没有大类时全放在一组
    private var groups: [(id: String, name: String)] {
        config.groups.isEmpty ? [("other", "全部")] : config.groups.map { ($0.id, $0.nameZh) }
    }

    /// 至少留一个兴趣
    private func selected(_ id: String) -> Binding<Bool> {
        Binding(
            get: { config.draft.news.topics.contains(id) },
            set: { on in
                var ids = config.draft.news.topics.filter { $0 != id }
                if on { ids.append(id) }
                if !ids.isEmpty { config.draft.news.topics = ids }
            }
        )
    }
}
