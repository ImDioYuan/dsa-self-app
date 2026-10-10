import Foundation
import Observation

/// 支持的货币
enum Currency: String, CaseIterable, Codable, Sendable, Identifiable {
    case AUD, CNY, USD, EUR, GBP, JPY, HKD, NZD, SGD, CAD, KRW

    /// 内部统一换算成 AUD
    static let base = Currency.AUD

    var id: String { rawValue }

    var name: String {
        switch self {
        case .AUD: "澳元"
        case .CNY: "人民币"
        case .USD: "美元"
        case .EUR: "欧元"
        case .GBP: "英镑"
        case .JPY: "日元"
        case .HKD: "港币"
        case .NZD: "新西兰元"
        case .SGD: "新加坡元"
        case .CAD: "加元"
        case .KRW: "韩元"
        }
    }

    var fractionDigits: Int {
        switch self {
        case .JPY, .KRW: 0
        default: 2
        }
    }

    /// "AUD 澳元"
    var label: String { "\(rawValue) \(name)" }
}

/// 汇率表：1 AUD = rates[X] 个 X
struct RateTable: Codable, Equatable, Sendable {
    var date: String
    var rates: [String: Double]

    /// 1 AUD 能换多少该货币
    func perAUD(_ currency: Currency) -> Double? {
        currency == .base ? 1 : rates[currency.rawValue]
    }

    /// 1 单位该货币 = 多少 AUD
    func rateToBase(_ currency: Currency) -> Double? {
        perAUD(currency).flatMap { $0 > 0 ? 1 / $0 : nil }
    }

    /// AUD 金额换成目标货币
    func fromBase(_ aud: Double, to currency: Currency) -> Double {
        aud * (perAUD(currency) ?? 1)
    }

    /// 完全离线、从没拉到过汇率时的兜底（2026-10-01 欧洲央行数据）
    static let fallback = RateTable(date: "2026-10-01", rates: [
        "CAD": 0.99016, "CNY": 4.66, "EUR": 0.6152, "GBP": 0.52521, "HKD": 5.4542, "JPY": 109.81,
        "KRW": 946.15, "NZD": 1.2378, "SGD": 0.88957, "USD": 0.69505,
    ])
}

/// 汇率：来自 Frankfurter（欧洲央行数据，免费、无需 key），按天缓存
@MainActor
@Observable
final class ExchangeRates {
    static let shared = ExchangeRates()

    /// 最新汇率，用来把 AUD 汇总换成显示货币
    private(set) var latest: RateTable

    private let defaults = UserDefaults.standard
    private static let latestKey = "rates.latest"
    private static let latestFetchedKey = "rates.latestFetchedAt"
    private static let historyKey = "rates.history"
    private static let symbols = Currency.allCases.filter { $0 != .base }.map(\.rawValue).joined(separator: ",")

    private init() {
        latest = (defaults.data(forKey: Self.latestKey)).flatMap { try? JSONDecoder().decode(RateTable.self, from: $0) } ?? .fallback
    }

    /// 距离上次更新超过 12 小时就拉一次最新汇率
    func refreshIfNeeded() async {
        let last = defaults.double(forKey: Self.latestFetchedKey)
        guard Date.now.timeIntervalSince1970 - last > 12 * 3600 else { return }
        guard let table = try? await Self.fetch(path: "latest") else { return }
        latest = table
        defaults.set(try? JSONEncoder().encode(table), forKey: Self.latestKey)
        defaults.set(Date.now.timeIntervalSince1970, forKey: Self.latestFetchedKey)
    }

    /// 某天 1 单位该货币 = 多少 AUD。查不到当天的就用最新的
    func rateToBase(_ currency: Currency, on date: Date) async -> Double {
        if currency == .base { return 1 }
        let day = Self.dayString(date)
        var history = (defaults.dictionary(forKey: Self.historyKey) as? [String: [String: Double]]) ?? [:]

        if let cached = history[day], let rate = RateTable(date: day, rates: cached).rateToBase(currency) {
            return rate
        }
        // 今天或未来的日期直接用最新汇率
        if date > Date.now.addingTimeInterval(-24 * 3600) {
            await refreshIfNeeded()
            return latest.rateToBase(currency) ?? 1
        }
        if let table = try? await Self.fetch(path: day) {
            history[day] = table.rates
            saveHistory(history)
            if let rate = table.rateToBase(currency) { return rate }
        }
        return latest.rateToBase(currency) ?? 1
    }

    /// 一次拉下一段时间的历史汇率（CSV 导入外币账单时用，不用一天请求一次）
    func preloadHistory(from start: Date, to end: Date) async {
        let calendar = Calendar.current
        // 今天的用最新汇率；最多回看 400 天（缓存也只留这么多）
        let end = min(end, Date.now.addingTimeInterval(-24 * 3600))
        let start = max(start, end.addingTimeInterval(-400 * 86_400))
        guard start <= end else { return }

        var days: [String] = []
        var day = calendar.startOfDay(for: start)
        while day <= end {
            days.append(Self.dayString(day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        var history = (defaults.dictionary(forKey: Self.historyKey) as? [String: [String: Double]]) ?? [:]
        guard let first = days.first, let last = days.last, days.contains(where: { history[$0] == nil }),
              let series = try? await Self.fetchSeries(from: first, to: last) else { return }

        // 周末、节假日没有数据：沿用前一个工作日（和单日接口一样）
        let available = series.rates.keys.sorted()
        var current = (available.last { $0 <= first } ?? available.first).flatMap { series.rates[$0] }
        for day in days {
            if let rates = series.rates[day] { current = rates }
            if history[day] == nil, let current { history[day] = current }
        }
        saveHistory(history)
    }

    /// 只保留最近 400 天的缓存
    private func saveHistory(_ history: [String: [String: Double]]) {
        var history = history
        if history.count > 400 {
            for key in history.keys.sorted().prefix(history.count - 400) { history[key] = nil }
        }
        defaults.set(history, forKey: Self.historyKey)
    }

    private struct Series: Decodable {
        var rates: [String: [String: Double]]
    }

    private static func fetchSeries(from: String, to: String) async throws -> Series {
        let url = URL(string: "https://api.frankfurter.dev/v1/\(from)..\(to)?base=AUD&symbols=\(symbols)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Series.self, from: data)
    }

    private static func fetch(path: String) async throws -> RateTable {
        let url = URL(string: "https://api.frankfurter.dev/v1/\(path)?base=AUD&symbols=\(symbols)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(RateTable.self, from: data)
    }

    static func dayString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}

// MARK: - 格式化

enum Money {
    /// 12.5 + AUD → "A$12.50"
    static func format(_ value: Double, _ currency: Currency) -> String {
        let style = FloatingPointFormatStyle<Double>.Currency(code: currency.rawValue, locale: Locale(identifier: "zh_CN"))
            .precision(.fractionLength(currency.fractionDigits))
        return value.formatted(style)
    }

    static func format(_ value: Decimal, _ currency: Currency) -> String {
        format(NSDecimalNumber(decimal: value).doubleValue, currency)
    }

    /// 图表坐标轴用的紧凑写法：1.2万 / 3.4k
    static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(2)).locale(Locale(identifier: "zh_CN")))
    }
}
