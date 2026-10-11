import SwiftUI

/// 新闻设置：显示语言、我的兴趣（入口）、简报（每天几条、几点前生成好）、关注的城市、汇率、「对你的影响」分哪几方面、自定义新闻源
struct NewsSettingsView: View {
    @State private var store = ConfigStore.shared
    /// 只存在这台设备上，不用保存到 Worker
    @AppStorage(NewsLanguage.storageKey) private var languageRaw = NewsLanguage.zh.rawValue
    @State private var addingPlace = false
    @State private var editingInterest: InterestDraft?
    @State private var fxBase = Currency.AUD
    @State private var fxQuote = Currency.CNY
    @State private var feedName = ""
    @State private var feedURL = ""

    var body: some View {
        ConfigForm(title: "新闻") { $config in
            languageSection
            topicsSection($config)
            briefSection($config)
            placesSection($config)
            fxSection($config)
            interestsSection($config)
            feedsSection($config)
        }
        .sheet(isPresented: $addingPlace) {
            PlaceSearchSheet { place in
                var places = store.draft.news.places
                var place = place
                place.id = ConfigFormat.uniqueID(place.id, existing: places.map(\.id))
                places.append(place)
                store.draft.news.places = places
            }
        }
        .sheet(item: $editingInterest) { draft in
            InterestEditor(draft: draft) { interest in
                var list = store.draft.news.interests
                if let index = list.firstIndex(where: { $0.id == draft.original?.id }) {
                    list[index] = interest
                } else {
                    var interest = interest
                    interest.id = ConfigFormat.uniqueID(interest.id, existing: list.map(\.id))
                    list.append(interest)
                }
                store.draft.news.interests = list
            }
        }
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section {
            Picker("显示语言", selection: $languageRaw) {
                ForEach(NewsLanguage.allCases, id: \.self) { language in
                    Text(language.title).tag(language.rawValue)
                }
            }
        } footer: {
            Text("新闻页和深度报道用这种语言显示。每份简报都同时写了中英文，切换马上生效。")
        }
    }

    // MARK: - 兴趣

    private func topicsSection(_ config: Binding<UserConfig>) -> some View {
        Section {
            NavigationLink {
                InterestsView()
            } label: {
                LabeledContent("我的兴趣", value: "\(config.wrappedValue.news.topics.count) 个")
            }
        }
    }

    // MARK: - 简报：条数和时间

    private func briefSection(_ config: Binding<UserConfig>) -> some View {
        Section {
            Stepper(value: config.news.count, in: UserConfig.countRange, step: 5) {
                LabeledContent("每天", value: "\(config.wrappedValue.news.count) 条")
            }
            DatePicker("几点前生成好", selection: Binding(
                get: { ConfigFormat.date(from: config.wrappedValue.news.briefTime) },
                set: { config.wrappedValue.news.briefTime = ConfigFormat.hhmm($0) }
            ), displayedComponents: .hourAndMinute)
        } header: {
            Text("简报")
        } footer: {
            if let usd = config.wrappedValue.estimatedBriefUSD(providers: store.providers, topics: store.topics) {
                Text("按设备时区。每份约 \(usd.formatted(.currency(code: "USD").precision(.fractionLength(2))))，实际花费见新闻页底部。")
            }
        }
    }

    // MARK: - 城市

    private func placesSection(_ config: Binding<UserConfig>) -> some View {
        Section {
            ForEach(config.wrappedValue.news.places) { place in
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.nameZh.isEmpty ? place.nameEn : place.nameZh)
                    Text([place.nameEn, place.admin1, place.country].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete { config.wrappedValue.news.places.remove(atOffsets: $0) }
            .onMove { config.wrappedValue.news.places.move(fromOffsets: $0, toOffset: $1) }
            if config.wrappedValue.news.places.count < UserConfig.maxPlaces {
                Button {
                    addingPlace = true
                } label: {
                    Label("添加城市", systemImage: "plus")
                }
            }
        } header: {
            Text("关注的城市")
        } footer: {
            Text("简报写这些城市的天气，极端天气会提醒。")
        }
    }

    // MARK: - 汇率

    private func fxSection(_ config: Binding<UserConfig>) -> some View {
        Section {
            ForEach(config.wrappedValue.news.fxPairs, id: \.self) { pair in
                Text(pair)
            }
            .onDelete { config.wrappedValue.news.fxPairs.remove(atOffsets: $0) }
            if config.wrappedValue.news.fxPairs.count < UserConfig.maxFxPairs {
                HStack {
                    Picker("", selection: $fxBase) {
                        ForEach(Currency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    Text("/")
                    Picker("", selection: $fxQuote) {
                        ForEach(Currency.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    Spacer()
                    Button("添加") {
                        config.wrappedValue.news.fxPairs.append("\(fxBase.rawValue)/\(fxQuote.rawValue)")
                    }
                    .disabled(fxBase == fxQuote || config.wrappedValue.news.fxPairs.contains("\(fxBase.rawValue)/\(fxQuote.rawValue)"))
                }
            }
        } header: {
            Text("汇率")
        }
    }

    // MARK: - 对你的影响

    private func interestsSection(_ config: Binding<UserConfig>) -> some View {
        Section {
            ForEach(config.wrappedValue.news.interests) { interest in
                Button {
                    editingInterest = InterestDraft(original: interest)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: ImpactArea(interest.id).systemImage)
                            .foregroundStyle(ImpactArea(interest.id).tint)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(interest.nameZh).foregroundStyle(.primary)
                            if !interest.hint.isEmpty {
                                Text(interest.hint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
            }
            .onDelete { offsets in
                // 至少留一个
                guard config.wrappedValue.news.interests.count > offsets.count else { return }
                config.wrappedValue.news.interests.remove(atOffsets: offsets)
            }
            if config.wrappedValue.news.interests.count < UserConfig.maxInterests {
                Button {
                    editingInterest = InterestDraft(original: nil)
                } label: {
                    Label("添加一方面", systemImage: "plus")
                }
            }
        } header: {
            Text("对你的影响")
        } footer: {
            Text("每天按这几方面总结新闻对你的影响。")
        }
    }

    // MARK: - 自定义新闻源

    private func feedsSection(_ config: Binding<UserConfig>) -> some View {
        Section {
            ForEach(config.wrappedValue.news.customFeeds, id: \.url) { feed in
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.name)
                    Text(feed.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .onDelete { config.wrappedValue.news.customFeeds.remove(atOffsets: $0) }
            if config.wrappedValue.news.customFeeds.count < UserConfig.maxCustomFeeds {
                TextField("名称", text: $feedName)
                TextField("RSS 链接 https://…", text: $feedURL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                Button("添加新闻源") {
                    config.wrappedValue.news.customFeeds.append(.init(
                        name: feedName.trimmingCharacters(in: .whitespaces),
                        url: feedURL.trimmingCharacters(in: .whitespaces)
                    ))
                    feedName = ""
                    feedURL = ""
                }
                .disabled(feedName.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: feedURL)?.scheme?.hasPrefix("http") != true)
            }
        } header: {
            Text("自定义新闻源")
        } footer: {
            Text("可选，任何 RSS 链接。")
        }
    }
}

// MARK: - 编辑「对你的影响」的一方面

struct InterestDraft: Identifiable {
    let id = UUID()
    /// nil = 新加的
    var original: UserConfig.Interest?
}

private struct InterestEditor: View {
    let draft: InterestDraft
    let onSave: (UserConfig.Interest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nameZh = ""
    @State private var nameEn = ""
    @State private var hint = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("中文名，例如：投资", text: $nameZh)
                    TextField("英文名，例如：Investing", text: $nameEn)
                } header: {
                    Text("名字")
                }
                Section {
                    TextEditor(text: $hint).frame(minHeight: 120)
                } header: {
                    Text("说明")
                } footer: {
                    Text("例如「我持有美股科技股」或「家里做进口生意，关心海运、汇率和关税」。")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.original == nil ? "添加" : "编辑")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        let zh = nameZh.trimmingCharacters(in: .whitespaces)
                        let en = nameEn.trimmingCharacters(in: .whitespaces)
                        onSave(.init(
                            id: draft.original?.id ?? ConfigFormat.slug(en.isEmpty ? "interest" : en),
                            nameZh: zh,
                            nameEn: en.isEmpty ? zh : en,
                            hint: hint.trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        dismiss()
                    }
                    .disabled(nameZh.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                nameZh = draft.original?.nameZh ?? ""
                nameEn = draft.original?.nameEn ?? ""
                hint = draft.original?.hint ?? ""
            }
        }
        .macSheetFrame(minWidth: 420, minHeight: 360)
        .themedTint()
    }
}
