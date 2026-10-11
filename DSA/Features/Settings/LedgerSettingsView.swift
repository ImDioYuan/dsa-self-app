import SwiftUI

/// 记账的设置：邮件自动记账，以及操作按钮 / Siri / Apple Pay 的设置教程
struct LedgerSettingsView: View {
    @AppStorage(EmailChargeScanner.Key.enabled) private var emailChargesEnabled = true
    @State private var scanner = EmailChargeScanner.shared

    private var gmailSignedIn: Bool { GoogleAuth.isSignedIn }
    private var workerReady: Bool { (try? DSAClient.fromSettings()) != nil }

    /// 「上次检查：3 分钟前 · 新增 2 笔」
    private var status: String? {
        let zh = Locale(identifier: "zh_CN")
        if let s = scanner.lastSummary {
            if let error = s.error { return "检查失败：\(error)" }
            var text = "上次检查：\(s.date.formatted(.relative(presentation: .named).locale(zh)))"
            text += s.added.isEmpty ? " · 没有新的付款" : " · 新增 \(s.added.count) 笔（\(s.added.prefix(3).joined(separator: "、"))）"
            if s.duplicates > 0 { text += " · 跳过 \(s.duplicates) 笔已记过的" }
            return text
        }
        return EmailChargeScanner.lastRun.map { "上次检查：\($0.formatted(.relative(presentation: .named).locale(zh)))" }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $emailChargesEnabled) {
                    Label("邮件自动记账", systemImage: "envelope.badge")
                }
                if emailChargesEnabled {
                    Button {
                        Task { await scanner.run() }
                    } label: {
                        HStack {
                            Text("立即检查付款邮件")
                            Spacer()
                            if scanner.isRunning { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(scanner.isRunning || !gmailSignedIn || !workerReady)
                    if let status {
                        Text(status).font(.footnote).foregroundStyle(scanner.lastSummary?.error == nil ? Color.secondary : Color.red)
                    }
                }
            } footer: {
                Text(gmailSignedIn && workerReady ? "每天 8 点后第一次打开时，检查 Gmail 里的付款收据。" : "需要先连接 Gmail 和 Worker。")
            }

            Section("快捷记账") {
                ForEach([SetupStep.applePay, .quickEntry, .widgets, .csvImport].filter(SetupStep.visible.contains)) { step in
                    NavigationLink {
                        SetupStepView(step: step, showsSettingsLink: step == .csvImport)
                    } label: {
                        Label(step.title, systemImage: step.systemImage)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("记账")
    }
}
