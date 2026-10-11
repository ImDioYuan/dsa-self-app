import SwiftUI

/// 个人资料：称呼、关于我。AI 挑新闻、写「对你的影响」、分析邮件时都会参考
struct ProfileSettingsView: View {
    var body: some View {
        ConfigForm(title: "个人资料") { $config in
            Section("称呼") {
                TextField("例如：小明", text: $config.name)
            }

            Section {
                TextEditor(text: $config.about)
                    .frame(minHeight: 160)
            } header: {
                Text("关于我")
            } footer: {
                Text("身份、城市、学校专业、投资、在找的工作……写得越具体，新闻和提醒越准。")
            }
        }
    }
}
