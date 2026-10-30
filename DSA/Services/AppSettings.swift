import Foundation
import Security

/// UserDefaults 里的配置键（视图里用 @AppStorage 读写同一套键）
enum SettingsKey {
    static let workerURL = "workerURL"
    /// 旧版只有一个 Moodle 日历链接，启动后迁移到 icalFeeds
    static let moodleICalURL = "moodleICalURL"
    /// 订阅日历：[{name, url}] 的 JSON
    static let icalFeeds = "icalFeeds"
    /// 转发到 Gmail 的邮件所在的标签（例如学校邮箱），这些邮件标成 Outlook 来源
    static let gmailForwardedLabel = "gmailForwardedLabel"
    /// 额外的 Gmail 搜索：命中的邮件不管被分到哪个分类都会分析（配合 Worker 的特别关注）
    static let gmailExtraQuery = "gmailExtraQuery"
    static let useCalendar = "useCalendar"
    static let useReminders = "useReminders"
    static let lastSyncAt = "lastSyncAt"
    static let googleClientID = "googleClientID"
    /// Gmail 登录过期的时间（timeIntervalSince1970，0 = 没过期）。今日页一直提醒到重新登录
    static let gmailExpiredAt = "gmailExpiredAt"
    /// 离截止不到多少小时算「紧急」（四象限的横轴分界）
    static let urgentHorizonHours = "urgentHorizonHours"
}

/// 非视图代码读取配置
enum AppSettings {
    private static var defaults: UserDefaults { .standard }

    static var workerURL: URL? {
        url(from: defaults.string(forKey: SettingsKey.workerURL))
    }

    /// 订阅日历（Moodle、Canvas、Google 日历、Outlook 等导出的 iCal 链接）
    static var icalFeeds: [ICalFeed] {
        get {
            migrateMoodleURL()
            guard let data = defaults.data(forKey: SettingsKey.icalFeeds) else { return [] }
            return (try? JSONDecoder().decode([ICalFeed].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: SettingsKey.icalFeeds) }
    }

    /// 旧版的 Moodle 链接变成一条名为「Moodle」的订阅，任务标签不变
    private static func migrateMoodleURL() {
        guard defaults.object(forKey: SettingsKey.icalFeeds) == nil else { return }
        let old = defaults.string(forKey: SettingsKey.moodleICalURL)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feeds = old.isEmpty ? [] : [ICalFeed(name: "Moodle", url: old)]
        defaults.set(try? JSONEncoder().encode(feeds), forKey: SettingsKey.icalFeeds)
        defaults.removeObject(forKey: SettingsKey.moodleICalURL)
    }

    static var gmailForwardedLabel: String? { nonEmpty(SettingsKey.gmailForwardedLabel) }
    static var gmailExtraQuery: String? { nonEmpty(SettingsKey.gmailExtraQuery) }

    private static func nonEmpty(_ key: String) -> String? {
        let value = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    static var useCalendar: Bool { defaults.bool(forKey: SettingsKey.useCalendar) }
    static var useReminders: Bool { defaults.bool(forKey: SettingsKey.useReminders) }

    static var lastSyncAt: Date? {
        get {
            let t = defaults.double(forKey: SettingsKey.lastSyncAt)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: SettingsKey.lastSyncAt) }
    }

    /// Worker 的访问口令存在钥匙串里
    static var workerToken: String? {
        get { Keychain.read("workerToken") }
        set { Keychain.write("workerToken", value: newValue) }
    }

    private static func url(from raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
}

/// 一个订阅日历
struct ICalFeed: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    /// 显示在任务上的来源名字，例如「Moodle」「课表」
    var name: String
    var url: String

    /// 导出的链接有时是 webcal://，改成 https:// 才能用 URLSession 下载
    var downloadURL: URL? {
        var raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("webcal://") { raw = "https://" + raw.dropFirst("webcal://".count) }
        return URL(string: raw)
    }
}

/// 极简钥匙串封装：只存字符串
enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "dsa"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var attrs = base
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
