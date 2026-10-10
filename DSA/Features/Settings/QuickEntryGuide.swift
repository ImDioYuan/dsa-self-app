import SwiftUI

/// 操作按钮、Siri、Apple Pay 自动记账的设置说明
struct QuickEntryGuide: View {
    var body: some View {
        Form {
            Section {
                step(1, "打开「设置」→「操作按钮」")
                step(2, "左右滑到「快捷指令」，点「选取快捷指令」")
                step(3, "找到 DSA，选「记一笔」")
            } header: {
                Label("操作按钮记一笔", systemImage: "button.horizontal.top.press")
            } footer: {
                Text("以后按一下机身左侧的操作按钮，就会打开 DSA 并弹出记一笔。")
            }

            Section {
                Text("「嘿 Siri，DSA 记一笔」→ 打开记一笔")
                Text("「嘿 Siri，用 DSA 记一笔支出」→ Siri 会问金额和分类，不用打开 app")
            } header: {
                Label("Siri", systemImage: "mic")
            }

            Section {
                step(1, "打开「快捷指令」app → 底部「自动化」→ 右上角「+」")
                step(2, "选「钱包」，勾选你的卡（可以全选），选「立即运行」，然后「下一步」")
                step(3, "选「新建空白自动化」→「添加操作」→ 搜索「DSA」→ 选「记录 Apple Pay 交易」")
                step(4, "点「金额」→ 选「快捷指令输入」→ 再点一次改成「金额」")
                step(5, "点「商家」→ 同样选「快捷指令输入」→ 改成「商家」，点「完成」")
            } header: {
                Label("Apple Pay 自动记账", systemImage: "wallet.pass")
            } footer: {
                Text("以后每次用 Apple Pay 刷卡，DSA 会自动记一笔，并按商家自动分类（第一次遇到的商家会问 Claude，之后记住）。在记账页改过分类后，下次同一个商家就用你改的分类。\n只有 Apple Pay 刷卡会触发；网购输卡号、自动扣款不会，这些可以在记账页右上角「导入 CSV」，用银行导出的流水补上。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("记账快捷方式")
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: .circle)
            Text(text)
        }
    }
}
