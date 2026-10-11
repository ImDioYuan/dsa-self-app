import SwiftUI

/// AI 服务：哪几家配好了 key，三组功能（任务和记账、每日简报、深度报道）各用哪家的哪个模型
struct AISettingsView: View {
    @State private var store = ConfigStore.shared

    var body: some View {
        ConfigForm(title: "AI 模型") { $config in
            Section {
                ForEach(store.providers) { provider in
                    // 右边不能用 Label：表单会把它当成这一行的标题来排，行被撑高、分隔线只剩一截
                    LabeledContent {
                        StepStateView(state: provider.configured ? .done("已配置") : .todo("未配置"))
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name)
                            Text(provider.keyName).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink("怎么添加 API key") { SetupStepView(step: .aiKeys, showsSettingsLink: false) }
            } header: {
                Text("服务商")
            } footer: {
                Text("key 存在你的 Worker 里。添加后下拉刷新。")
            }

            ForEach(AITask.allCases) { task in
                taskSection(task, config: $config)
            }
        }
        .refreshable { await store.load() }
    }

    private func taskSection(_ task: AITask, config: Binding<UserConfig>) -> some View {
        let choice = config.wrappedValue.choice(for: task)
        let resolved = config.wrappedValue.resolved(task, providers: store.providers)
        return Section {
            Picker("服务商", selection: Binding(
                get: { choice?.provider ?? "" },
                set: { id in
                    // 换服务商时模型清空 = 用这家的默认模型
                    config.wrappedValue.setChoice(id.isEmpty ? nil : .init(provider: id, model: ""), for: task)
                }
            )) {
                Text("自动（第一家已配置的）").tag("")
                ForEach(store.providers) { provider in
                    Text(provider.configured ? provider.name : "\(provider.name)（未配置）").tag(provider.id)
                }
            }

            if let choice, let provider = store.providers.first(where: { $0.id == choice.provider }) {
                HStack {
                    TextField(provider.defaults[task.rawValue] ?? "模型", text: Binding(
                        get: { choice.model },
                        set: { config.wrappedValue.setChoice(.init(provider: choice.provider, model: $0), for: task) }
                    ))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    Menu {
                        ForEach(provider.models, id: \.id) { model in
                            Button(model.id) {
                                config.wrappedValue.setChoice(.init(provider: choice.provider, model: model.id), for: task)
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                }
            }
        } header: {
            Text(task.title)
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.footnote)
                if let resolved {
                    Text("现在用：\(resolved.provider.name) · \(resolved.model)")
                    if !resolved.provider.configured {
                        Text("\(resolved.provider.name) 还没有配置 key，这项功能会报错。").foregroundStyle(.red)
                    }
                    if task == .tasks, resolved.provider.models.first(where: { $0.id == resolved.model })?.vision == false {
                        Text("这个模型不能看图，拍小票识别会失败。").foregroundStyle(.orange)
                    }
                    if task == .report, !resolved.provider.webSearch {
                        Text("\(resolved.provider.name) 没有联网搜索，深度报道只能读新闻原文。").foregroundStyle(.orange)
                    }
                } else {
                    Text("还没有配置任何服务商的 key。").foregroundStyle(.red)
                }
            }
        }
    }
}
