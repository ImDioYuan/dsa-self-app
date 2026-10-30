import AuthenticationServices
import SwiftData
import SwiftUI

/// Gmail：登录、重新分析、转发标签。今日（邮件里要做的事）和邮件自动记账都靠它读邮件
struct GmailSettingsView: View {
    let sync: TaskSyncService

    @Environment(\.modelContext) private var context
    @Environment(\.webAuthenticationSession) private var webAuthSession
    @AppStorage(SettingsKey.googleClientID) private var googleClientID = ""
    @AppStorage(SettingsKey.gmailForwardedLabel) private var forwardedLabel = ""
    @AppStorage(SettingsKey.gmailExpiredAt) private var expiredAt = 0.0
    @State private var signedIn = GoogleAuth.isSignedIn
    @State private var email = GoogleAuth.tokens?.email
    @State private var error: String?
    @State private var signingIn = false

    var body: some View {
        Form {
            Section {
                if signedIn {
                    LabeledContent("账号") { Text(email ?? "已登录").foregroundStyle(.secondary) }
                    Button("重新分析最近 3 天的邮件") {
                        AnalyzedLog.gmail.reset()
                        Task { await sync.sync(context: context) }
                    }
                    .disabled(sync.isSyncing)
                    Button("退出 Gmail", role: .destructive) {
                        GoogleAuth.signOut()
                        signedIn = false
                        email = nil
                    }
                } else {
                    TextField("Google OAuth Client ID", text: $googleClientID, axis: .vertical)
                        .urlInput()
                    Button(action: signIn) {
                        HStack {
                            Label("登录 Gmail", systemImage: "envelope")
                            Spacer()
                            if signingIn { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(googleClientID.isEmpty || signingIn)
                    // 登录过期后今日页会一直提醒；这台设备不想再用 Gmail 时从这里关掉
                    if expiredAt > 0 {
                        Button("不再使用 Gmail") { GoogleAuth.signOut() }
                    }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                Text("新邮件交给你的 Worker 里的 AI 判断要不要处理，分析过的不会重复发送。")
            }

            Section {
                TextField("标签名，例如 School", text: $forwardedLabel)
                    .urlInput()
            } header: {
                Text("转发邮件的标签（可选）")
            } footer: {
                Text("学校或公司邮箱转发到 Gmail 并归到这个标签后，会标成 Outlook 来源。")
            }

            Section {
                NavigationLink("怎么拿 Client ID") { SetupStepView(step: .gmail, showsSettingsLink: false) }
                NavigationLink("怎么设置学校邮箱转发") { SetupStepView(step: .forwarding, showsSettingsLink: false) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Gmail")
    }

    private func signIn() {
        signingIn = true
        error = nil
        Task {
            defer { signingIn = false }
            do {
                try await GoogleAuth.signIn(using: webAuthSession)
                signedIn = true
                email = GoogleAuth.tokens?.email
            } catch GoogleAuth.AuthError.cancelled {
                // 用户自己关掉了登录页，不提示
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
