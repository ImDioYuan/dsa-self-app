import SwiftUI

// MARK: - 背景

/// 全局柔和渐变背景，颜色由主题色生成，让上面的液态玻璃有东西可以折射
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(ThemeStore.key, store: ThemeStore.defaults) private var themeRaw = ThemeColor.default.storage

    var body: some View {
        let palette = ThemePalette(base: ThemeColor(storage: themeRaw) ?? .default)
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [0.6, 0.45], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ],
            colors: palette.backgroundColors(dark: scheme == .dark)
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.4), value: themeRaw)
    }
}

extension View {
    /// 按钮、选中状态等强调色跟随主题；浅色 / 深色跟随「外观模式」
    func themedTint() -> some View { modifier(ThemedTint()) }
}

private struct ThemedTint: ViewModifier {
    @AppStorage(ThemeStore.key, store: ThemeStore.defaults) private var themeRaw = ThemeColor.default.storage
    @AppStorage(ThemeStore.appearanceKey, store: ThemeStore.defaults) private var appearanceRaw = AppearanceMode.system.rawValue
    #if os(iOS)
    @State private var system = SystemAppearance.shared
    @Environment(\.scenePhase) private var scenePhase
    #endif

    func body(content: Content) -> some View {
        let mode = AppearanceMode(rawValue: appearanceRaw) ?? .system
        #if os(iOS)
        // 「跟随系统」也给出明确的浅色 / 深色：如果传 nil，已经弹出的设置页不会跟着切换
        let scheme: ColorScheme? = mode.colorScheme ?? system.scheme
        #else
        let scheme = mode.colorScheme
        #endif
        return content
            .tint(ThemePalette(base: ThemeColor(storage: themeRaw) ?? .default).accent)
            .preferredColorScheme(scheme)
            #if os(iOS)
            .onAppear { system.start() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { system.refresh() }
            }
            .onChange(of: appearanceRaw) { _, _ in system.refresh() }
            #endif
    }
}

#if os(iOS)
import UIKit

/// 系统当前是浅色还是深色。读的是屏幕的外观（系统级设置），不受 app 自己选的浅色 / 深色影响；
/// 系统切换（包括日落后自动切换）时会实时更新
@MainActor
@Observable
final class SystemAppearance {
    static let shared = SystemAppearance()

    private(set) var scheme: ColorScheme = .light
    @ObservationIgnored private var registration: (any UITraitChangeRegistration)?

    private init() {
        if let screen = Self.screen { update(screen.traitCollection) }
    }

    private static var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    private static var screen: UIScreen? { scene?.screen }

    /// 重新读取系统外观。app 回到前台时调用（从控制中心切换深色、从设置 app 返回都会触发）
    func refresh() {
        if let screen = Self.screen { update(screen.traitCollection) }
    }

    func start() {
        refresh()
        guard registration == nil, let scene = Self.scene else { return }
        // 场景外观有变化时重新读一次屏幕的外观
        registration = scene.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: UIWindowScene, _: UITraitCollection) in
            self?.refresh()
        }
        // app 自己指定了浅色 / 深色时，系统切换不一定会通知到场景，所以前台时每秒再看一眼（只读一个属性，几乎不耗电）
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard UIApplication.shared.applicationState == .active else { continue }
                self?.refresh()
            }
        }
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private func update(_ traits: UITraitCollection) {
        let newValue: ColorScheme = traits.userInterfaceStyle == .dark ? .dark : .light
        if newValue != scheme { scheme = newValue }
    }
}
#endif

// MARK: - 玻璃卡片

extension View {
    /// 统一的液态玻璃卡片样式
    func glassCard(cornerRadius: CGFloat = 22, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }

    /// 弹出页的最小尺寸只给 Mac 窗口用。iPhone 屏幕比这窄（Pro 402pt、mini 375pt），
    /// 设了会把两边的「取消」「完成」挤出屏幕
    @ViewBuilder
    func macSheetFrame(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}

// MARK: - 颜色

extension Quadrant {
    var tint: Color {
        switch self {
        case .doNow: .red
        case .plan: .blue
        case .quick: .orange
        case .later: .gray
        }
    }
}

extension TaskSource {
    var tint: Color {
        switch self {
        case .gmail: .red
        case .outlook: .blue
        case .ical: .orange
        case .calendar: .pink
        case .reminders: .indigo
        case .shared: .green
        case .manual: .gray
        }
    }
}

// MARK: - 小组件

/// 圆角小标签，例如「截止」「约会」
struct Pill: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
    }
}
