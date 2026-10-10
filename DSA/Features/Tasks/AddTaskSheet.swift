import SwiftData
import SwiftUI

/// 手动添加一条任务
struct AddTaskSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var kind = TaskKind.deadline
    @State private var importance = Importance.important
    @State private var hasDue = true
    @State private var due = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("要做什么？", text: $title)
                    TextField("备注", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                }
                Section {
                    Picker("类型", selection: $kind) {
                        ForEach(TaskKind.allCases.filter { $0 != .info }, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("重要程度", selection: $importance) {
                        ForEach(Importance.allCases.reversed(), id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("紧急程度不用选：离截止越近越紧急，DSA 会按截止时间自动放进四象限。")
                }
                Section {
                    Toggle("截止时间", isOn: $hasDue.animation())
                    if hasDue {
                        DatePicker("时间", selection: $due)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("新任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .macSheetFrame(minWidth: 360, minHeight: 360)
        // 弹出页是单独一层，也要跟随主题和浅色 / 深色，切换时才能立刻变
        .themedTint()
    }

    private func save() {
        let draft = TaskDraft(
            sourceID: "manual:\(UUID().uuidString)",
            title: title.trimmingCharacters(in: .whitespaces),
            detail: note,
            source: .manual,
            kind: kind,
            importance: importance,
            due: hasDue ? due : nil
        )
        context.insert(TaskItem(draft: draft))
        try? context.save()
        dismiss()
    }
}
