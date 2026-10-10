import SwiftUI

/// 主题色（Display P3）。用户在调色盘里选一个颜色，app 背景、按钮和小组件都由它生成
struct ThemeColor: Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    /// 默认：蓝紫色（生成的背景就是一开始那套蓝紫粉渐变）
    static let `default` = ThemeColor(red: 0.55, green: 0.45, blue: 0.98)

    static let presets: [(name: String, color: ThemeColor)] = [
        ("默认", .default),
        ("海洋", ThemeColor(red: 0.20, green: 0.55, blue: 0.95)),
        ("薄荷", ThemeColor(red: 0.20, green: 0.78, blue: 0.62)),
        ("日落", ThemeColor(red: 1.00, green: 0.50, blue: 0.35)),
        ("樱花", ThemeColor(red: 0.98, green: 0.45, blue: 0.65)),
        ("森林", ThemeColor(red: 0.30, green: 0.62, blue: 0.35)),
        ("午夜", ThemeColor(red: 0.25, green: 0.30, blue: 0.62)),
    ]

    var color: Color { Color(.displayP3, red: red, green: green, blue: blue) }

    // MARK: 存储："r,g,b"

    var storage: String { String(format: "%.4f,%.4f,%.4f", red, green, blue) }

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(storage: String) {
        let parts = storage.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        self.init(red: parts[0], green: parts[1], blue: parts[2])
    }

    /// 从调色盘选出的 Color 转成 P3 分量
    init?(_ color: Color) {
        let resolved = color.resolve(in: EnvironmentValues())
        guard let p3 = CGColorSpace(name: CGColorSpace.displayP3),
              let converted = resolved.cgColor.converted(to: p3, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        self.init(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2]))
    }

    // MARK: HSB

    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let maxV = max(red, green, blue), minV = min(red, green, blue), delta = maxV - minV
        var hue = 0.0
        if delta > 0 {
            if maxV == red { hue = (green - blue) / delta }
            else if maxV == green { hue = 2 + (blue - red) / delta }
            else { hue = 4 + (red - green) / delta }
            hue = (hue / 6).truncatingRemainder(dividingBy: 1)
            if hue < 0 { hue += 1 }
        }
        return (hue, maxV == 0 ? 0 : delta / maxV, maxV)
    }

    static func hsb(_ h: Double, _ s: Double, _ b: Double) -> ThemeColor {
        let h = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * 6
        let s = min(max(s, 0), 1), b = min(max(b, 0), 1)
        let i = Int(h), f = h - Double(i)
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        switch i {
        case 0: return ThemeColor(red: b, green: t, blue: p)
        case 1: return ThemeColor(red: q, green: b, blue: p)
        case 2: return ThemeColor(red: p, green: b, blue: t)
        case 3: return ThemeColor(red: p, green: q, blue: b)
        case 4: return ThemeColor(red: t, green: p, blue: b)
        default: return ThemeColor(red: b, green: p, blue: q)
        }
    }

    /// 和另一个颜色按比例混合（amount = 0 是自己，1 是 other）
    func mixed(with other: ThemeColor, _ amount: Double) -> ThemeColor {
        ThemeColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }

    static let white = ThemeColor(red: 1, green: 1, blue: 1)
    static let black = ThemeColor(red: 0, green: 0, blue: 0)
}

/// 由主题色生成的各处配色
struct ThemePalette {
    let base: ThemeColor

    /// 3×3 网格渐变（MeshGradient），每格的色相偏移和浓度
    private static let mesh: [(hueOffset: Double, strength: Double)] = [
        (-0.12, 0.11), (-0.04, 0.09), (0.10, 0.10),
        (-0.10, 0.12), (0.00, 0.03), (0.14, 0.11),
        (-0.20, 0.10), (-0.02, 0.07), (0.06, 0.12),
    ]

    /// app 背景：浅色模式是很淡的彩色，深色模式是带颜色的深底
    func backgroundColors(dark: Bool) -> [Color] {
        let (h, s, _) = base.hsb
        return Self.mesh.map { cell in
            let tint = ThemeColor.hsb(h + cell.hueOffset, max(s, 0.55), dark ? 0.75 : 1)
            return dark
                ? ThemeColor.black.mixed(with: tint, cell.strength * 2.6).color
                : ThemeColor.white.mixed(with: tint, cell.strength).color
        }
    }

    /// 小组件背景：饱和一些，配白字；深色模式稍微压暗（宝石色调，不发灰），晚上不刺眼
    func widgetColors(dark: Bool = false) -> [Color] {
        let (h, s, _) = base.hsb
        let sat = min(max(s, 0.45), 0.85)
        let b: (Double, Double, Double) = dark ? (0.70, 0.56, 0.66) : (0.92, 0.80, 0.88)
        let satScale = dark ? 1.08 : 1.0
        return [
            ThemeColor.hsb(h - 0.07, min(sat * 0.85 * satScale, 1), b.0).color,
            ThemeColor.hsb(h, min(sat * satScale, 1), b.1).color,
            ThemeColor.hsb(h + 0.10, min(sat * 0.8 * satScale, 1), b.2).color,
        ]
    }

    /// 设置里的预设色块：任何模式下都显示鲜艳的原色
    var swatchColors: [Color] {
        let (h, s, _) = base.hsb
        let sat = min(max(s, 0.5), 0.9)
        return [
            ThemeColor.hsb(h - 0.07, sat * 0.85, 0.98).color,
            ThemeColor.hsb(h + 0.08, sat, 0.88).color,
        ]
    }

    /// 按钮、强调色：太暗的颜色提亮一点
    var accent: Color {
        let (h, s, b) = base.hsb
        return ThemeColor.hsb(h, s, max(b, 0.7)).color
    }
}

/// 浅色 / 深色：默认跟随系统
enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    /// nil 表示跟随系统
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// 结合系统当前外观，算出实际是不是深色
    func isDark(system: ColorScheme) -> Bool {
        colorScheme.map { $0 == .dark } ?? (system == .dark)
    }
}

/// 主题存在 App Group 里，app 和小组件共用
enum ThemeStore {
    static let key = "theme.color"
    static let appearanceKey = "theme.appearance"

    static var appearance: AppearanceMode {
        defaults?.string(forKey: appearanceKey).flatMap(AppearanceMode.init) ?? .system
    }
    /// 全局只用这一个实例：多个 @AppStorage 用同一个 UserDefaults 对象，改动才能互相通知。
    /// UserDefaults 本身线程安全（苹果文档），只是没有标 Sendable
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: LedgerSnapshot.appGroup)

    static var current: ThemeColor {
        defaults?.string(forKey: key).flatMap(ThemeColor.init(storage:)) ?? .default
    }
}
