import SwiftUI
import WidgetKit

/// 桌面 / 锁屏小组件：今天花了多少、本月预算用了多少
struct TodaySpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TodaySpend", provider: SpendProvider()) { entry in
            TodaySpendView(entry: entry)
                // 背景跟随 app 的主题色（设置 → 外观）
                .containerBackground(for: .widget) {
                    WidgetBackground(theme: entry.theme, appearance: entry.appearance)
                }
                .widgetURL(URL(string: "dsa://ledger"))
        }
        .configurationDisplayName("今日支出")
        .description("今天花了多少，本月预算用了多少")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct SpendEntry: TimelineEntry {
    let date: Date
    let snapshot: LedgerSnapshot?
    var theme: ThemeColor = ThemeStore.current
    var appearance: AppearanceMode = ThemeStore.appearance
}

/// 主题渐变；外观模式是「跟随系统」时看系统当前是浅色还是深色
private struct WidgetBackground: View {
    let theme: ThemeColor
    let appearance: AppearanceMode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(colors: ThemePalette(base: theme).widgetColors(dark: appearance.isDark(system: scheme)),
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct SpendProvider: TimelineProvider {
    func placeholder(in context: Context) -> SpendEntry {
        SpendEntry(date: .now, snapshot: LedgerSnapshot(
            day: .now, todayExpense: 36.5, monthExpense: 820, monthBudget: 1500,
            currencyCode: "AUD", fractionDigits: 2, updatedAt: .now
        ))
    }

    func getSnapshot(in context: Context, completion: @escaping (SpendEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : SpendEntry(date: .now, snapshot: LedgerSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SpendEntry>) -> Void) {
        let entry = SpendEntry(date: .now, snapshot: LedgerSnapshot.load())
        // app 记账后会主动刷新；这里再在午夜刷新一次，让「今日」归零
        let midnight = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

struct TodaySpendView: View {
    let entry: SpendEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: LedgerSnapshot? { entry.snapshot }
    private var today: Double { snapshot?.todayExpense(now: entry.date) ?? 0 }
    private var month: Double { snapshot?.monthExpense(now: entry.date) ?? 0 }
    private var budget: Double { snapshot?.monthBudget ?? 0 }
    private var ratio: Double { budget > 0 ? month / budget : 0 }
    private func text(_ value: Double) -> String { snapshot?.format(value) ?? "—" }

    /// 彩色背景上：正常白色，快超支橙黄，超支粉红
    private var tint: Color {
        ratio >= 1 ? Color(red: 1, green: 0.75, blue: 0.8) : ratio >= 0.8 ? Color(red: 1, green: 0.85, blue: 0.4) : .white
    }

    var body: some View {
        content
            // 桌面小组件用白字（背景是主题渐变）；锁屏小组件交给系统着色
            .foregroundStyle(family.isAccessory ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Text("今日 \(text(today))")
        case .accessoryCircular:
            if budget > 0 {
                Gauge(value: min(ratio, 1)) {
                    Image(systemName: "creditcard")
                } currentValueLabel: {
                    Text("\(Int((ratio * 100).rounded()))%")
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                VStack(spacing: 0) {
                    Text("今日").font(.caption2)
                    Text(text(today)).font(.caption2.weight(.semibold)).minimumScaleFactor(0.5)
                }
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("今日支出").font(.caption2).foregroundStyle(.secondary)
                Text(text(today)).font(.headline).widgetAccentable()
                Text(budget > 0 ? "本月 \(text(month)) / \(text(budget))" : "本月 \(text(month))")
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        case .systemMedium:
            HStack(spacing: 16) {
                summary
                Rectangle().fill(.white.opacity(0.35)).frame(width: 1)
                VStack(alignment: .leading, spacing: 10) {
                    Link(destination: URL(string: "dsa://add")!) {
                        Label("记一笔", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.white.opacity(0.22), in: .capsule)
                    }
                    if budget > 0 {
                        Text("剩余 \(text(max(budget - month, 0)))")
                            .font(.caption)
                            .opacity(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("今日支出", systemImage: "creditcard")
                .font(.caption.weight(.medium))
                .opacity(0.85)
            Text(text(today))
                .font(.system(.title2, design: .rounded).weight(.bold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .widgetAccentable()
            Spacer(minLength: 0)
            Text("本月 \(text(month))")
                .font(.caption)
                .opacity(0.85)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if budget > 0 {
                ProgressView(value: min(ratio, 1))
                    .tint(tint)
                    .background(.white.opacity(0.25), in: .capsule)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension WidgetFamily {
    var isAccessory: Bool {
        switch self {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline: true
        default: false
        }
    }
}
