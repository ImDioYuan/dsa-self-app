import SwiftUI

/// 编辑 Worker 上的配置的页面（个人资料、新闻、AI 服务）：
/// 读不到时显示原因；有改动时右上角「保存」可点，离开页面时也会自动保存
struct ConfigForm<Content: View>: View {
    let title: String
    @ViewBuilder var content: (Binding<UserConfig>) -> Content

    @State private var store = ConfigStore.shared

    var body: some View {
        Form {
            if store.saved == nil {
                Section {
                    if store.isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Label(store.error ?? "还没有读取设置", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("重试") { Task { await store.load() } }
                    }
                } footer: {
                    Text("这些设置存在你自己部署的 Worker 里，需要先在设置里填好 Worker 地址和口令。")
                }
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
