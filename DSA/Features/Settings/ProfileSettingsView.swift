import SwiftUI

/// 个人资料：称呼、关于我、特别关注。AI 挑新闻、写「对你的影响」、分析邮件时都会参考
struct ProfileSettingsView: View {
    var body: some View {
        ConfigForm(title: "个人资料") { $config in
            Section {
                TextField("例如：小明", text: $config.name)
            } header: {
                Text("称呼")
            } footer: {
                Text("AI 在简报和提示里怎么称呼你。")
            }

            Section {
                TextEditor(text: $config.about)
                    .frame(minHeight: 160)
            } header: {
                Text("关于我")
            } footer: {
                Text("写你的身份、所在城市、关心的事，例如在读的学校和专业、投资、家里的生意、在找的工作。写得越具体，新闻挑得越准、「对你的影响」越有用。只存在你自己的 Worker 里。")
            }

            Section {
                ForEach(config.watchRules.indices, id: \.self) { index in
                    TextField("规则", text: $config.watchRules[index], axis: .vertical)
                        .lineLimit(2...6)
                }
                .onDelete { config.watchRules.remove(atOffsets: $0) }
                if config.watchRules.count < UserConfig.maxWatchRules {
                    Button {
                        config.watchRules.append("")
                    } label: {
                        Label("添加规则", systemImage: "plus")
                    }
                }
            } header: {
                Text("特别关注")
            } footer: {
                Text("命中的邮件即使不需要处理，也会出现在今日里。例如：「我在申请 X 公司的工作，招聘相关的邮件（测评、面试、offer、拒信）都要提醒，促销邮件不算」。左滑删除。")
            }

            Section {
                LabeledContent("时区", value: TimeZone.current.identifier)
            } footer: {
                Text("保存时自动使用这台设备的时区：新闻简报的日期和生成时间都按这个时区算。")
            }
        }
    }
}
