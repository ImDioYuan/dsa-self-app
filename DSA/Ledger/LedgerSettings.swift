import SwiftUI

/// 记账相关的 UserDefaults 键（视图里用 @AppStorage 读写同一套键）
enum LedgerSettingsKey {
    /// 汇总时显示的货币
    static let displayCurrency = "ledger.displayCurrency"
    /// 每月总预算（AUD），0 表示不设
    static let monthlyBudget = "ledger.monthlyBudgetAUD"
    /// 上次记账用的币种，下次默认选它
    static let lastCurrency = "ledger.lastCurrency"
    static let merchantMap = "ledger.merchantCategory"
}

enum LedgerSettings {
    static var displayCurrency: Currency {
        UserDefaults.standard.string(forKey: LedgerSettingsKey.displayCurrency).flatMap(Currency.init) ?? .base
    }

    static var lastCurrency: Currency {
        get { UserDefaults.standard.string(forKey: LedgerSettingsKey.lastCurrency).flatMap(Currency.init) ?? .base }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: LedgerSettingsKey.lastCurrency) }
    }

    static var monthlyBudget: Double { UserDefaults.standard.double(forKey: LedgerSettingsKey.monthlyBudget) }
}

/// 记住「商家 → 分类」：用户给某个商家选过一次分类，下次自动选上
enum MerchantMemory {
    static func category(for merchant: String) -> String? {
        let key = normalize(merchant)
        guard !key.isEmpty else { return nil }
        return (UserDefaults.standard.dictionary(forKey: LedgerSettingsKey.merchantMap) as? [String: String])?[key]
    }

    static func remember(merchant: String, categoryID: String) {
        let key = normalize(merchant)
        guard !key.isEmpty, !categoryID.isEmpty else { return }
        var map = (UserDefaults.standard.dictionary(forKey: LedgerSettingsKey.merchantMap) as? [String: String]) ?? [:]
        map[key] = categoryID
        UserDefaults.standard.set(map, forKey: LedgerSettingsKey.merchantMap)
    }

    /// "WOOLWORTHS 1234 SYDNEY AU" 和 "Woolworths" 算同一个商家：小写、去掉数字符号，只取第一个词。
    /// 少数第一个词区分不了商家的（Uber / Uber Eats、SQ *店名），取前两个词
    static func normalize(_ merchant: String) -> String {
        let words = merchant.lowercased()
            .replacingOccurrences(of: "[0-9#*.]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
        guard let first = words.first else { return "" }
        let ambiguous: Set<String> = ["uber", "the", "sq", "sumup", "paypal", "zlr", "ls"]
        return ambiguous.contains(first) ? words.prefix(2).joined(separator: " ") : first
    }
}

extension Color {
    /// "#FF9500" → Color
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0x8E8E93
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
