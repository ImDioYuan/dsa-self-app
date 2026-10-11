import SwiftUI

/// 编辑 Worker 上的配置的页面（个人资料、新闻、AI 服务）：读不到时显示原因
struct ConfigForm<Content: View>: View {
    let title: String
    @ViewBuilder var content: (Binding<UserConfig>) -> Content

    @State private var store = ConfigStore.shared

    var body: some View {
        Form {
            if store.saved == nil {
                ConfigUnavailableSection()
            } else {
                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                content($store.draft)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .configEditing()
    }
}

/// 还没读到 Worker 上的配置：读取中，或者读不到的原因和「重试」
struct ConfigUnavailableSection: View {
    @State private var store = ConfigStore.shared

    var body: some View {
        Section {
            if store.isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else {
                Label(store.error ?? "还没有读取设置", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("重试") { Task { await store.load() } }
            }
        } footer: {
            Text("需要先在 设置 → Worker 里填好地址和口令。")
        }
    }
}

extension View {
    /// 编辑 Worker 上的配置：进来时读取；有改动时右上角「保存」可点，离开页面时也会自动保存
    func configEditing() -> some View {
        modifier(ConfigEditing())
    }

    /// URL 输入框：关闭自动大写和自动纠错
    func urlInput() -> some View {
        #if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()
        #else
        self.autocorrectionDisabled()
        #endif
    }
}

private struct ConfigEditing: ViewModifier {
    @State private var store = ConfigStore.shared

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if store.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("保存") { Task { await store.save() } }
                            .disabled(!store.hasChanges)
                    }
                }
            }
            .task { await store.loadIfNeeded() }
            .onDisappear {
                if store.hasChanges { Task { await store.save() } }
            }
    }
}
