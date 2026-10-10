import SwiftUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// 设置里的「外观」：P3 调色盘 + 预设色，app 背景、按钮和桌面小组件一起变
struct ThemeSection: View {
    @AppStorage(ThemeStore.key, store: ThemeStore.defaults) private var themeRaw = ThemeColor.default.storage
    @AppStorage(ThemeStore.appearanceKey, store: ThemeStore.defaults) private var appearanceRaw = AppearanceMode.system.rawValue

    private var theme: ThemeColor { ThemeColor(storage: themeRaw) ?? .default }

    private var appearanceBinding: Binding<String> {
        Binding(
            get: { appearanceRaw },
            set: { newValue in
                withAnimation { appearanceRaw = newValue }
                reloadWidgets()
            }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { theme.color },
            set: { newValue in
                if let picked = ThemeColor(newValue) { apply(picked) }
            }
        )
    }

    var body: some View {
        Section {
            Picker(selection: appearanceBinding) {
                ForEach(AppearanceMode.allCases) { Text($0.title).tag($0.rawValue) }
            } label: {
                Label("外观模式", systemImage: "circle.lefthalf.filled")
            }
            .pickerStyle(.segmented)

            ColorPicker(selection: colorBinding, supportsOpacity: false) {
                Label("主题颜色", systemImage: "paintpalette")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(ThemeColor.presets, id: \.name) { preset in
                        Button { apply(preset.color) } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(LinearGradient(colors: ThemePalette(base: preset.color).swatchColors,
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 38, height: 38)
                                    .overlay {
                                        if preset.color == theme {
                                            Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                                        }
                                    }
                                Text(preset.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("外观")
        } footer: {
            Text("外观模式默认跟随系统（iPhone 设置里的浅色 / 深色，或定时自动切换），也可以固定成浅色或深色。app 背景、按钮颜色和桌面小组件会一起变。点「主题颜色」右边的色块可以用调色盘（网格 / 光谱 / 滑杆，支持 P3 广色域和吸管）。")
        }
    }

    private func apply(_ color: ThemeColor) {
        withAnimation { themeRaw = color.storage }
        reloadWidgets()
    }

    private func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
