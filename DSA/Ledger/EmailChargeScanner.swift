import Foundation
import Observation
import SwiftData

/// 邮件自动记账：每天 8 点后第一次打开 app（或系统后台刷新）时，扫描 Gmail 里的付款收据，
/// 让 Claude 提取扣款，去掉 Apple Pay 等已经记过的同一笔后写进账本
@MainActor
@Observable
final class EmailChargeScanner {
    static let shared = EmailChargeScanner()

    /// 每天几点之后检查
    nonisolated static let runHour = 8

    struct Summary: Equatable {
        var date: Date
        var added: [String] = []
        var duplicates = 0
        var error: String?
    }

    private(set) var isRunning = false
    private(set) var lastSummary: Summary?

    private init() {}

    // MARK: - 设置

    enum Key {
        static let enabled = "ledger.emailCharges.enabled"
        static let lastRun = "ledger.emailCharges.lastRun"
    }

    /// 默认开启
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Key.enabled) as? Bool ?? true
    }

    static var lastRun: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: Key.lastRun)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Key.lastRun) }
    }

    /// 今天 8 点之后，且今天 8 点之后还没检查过
    nonisolated static func isDue(now: Date, lastRun: Date?, hour: Int = runHour, calendar: Calendar = .current) -> Bool {
        guard let todayRun = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now), now >= todayRun else { return false }
        return lastRun.map { $0 < todayRun } ?? true
    }

    // MARK: - 运行

    func runIfDue(now: Date = .now) async {
        guard Self.isEnabled, GoogleAuth.isSignedIn, (try? DSAClient.fromSettings()) != nil,
              Self.isDue(now: now, lastRun: Self.lastRun) else { return }
        await run()
    }

    /// 立即检查（设置里的按钮）
    @discardableResult
    func run() async -> Summary {
        guard !isRunning else { return lastSummary ?? Summary(date: .now) }
        isRunning = true
        defer { isRunning = false }

        var summary = Summary(date: .now)
        do {
            summary = try await scan()
            Self.lastRun = .now
        } catch let error where error.isCancellation {
            // 被取消不算失败，下次打开再检查
            return lastSummary ?? summary
        } catch {
            summary.error = error.localizedDescription
        }
        lastSummary = summary
        return summary
    }

    private func scan() async throws -> Summary {
        let client = try DSAClient.fromSettings()
        let api = GmailAPI(accessToken: try await GoogleAuth.validAccessToken())

        // 第一次看最近 7 天；之后从上次检查往前多看一天，最多 14 天
        let days = Self.lastRun.map { min(max(Int(Date.now.timeIntervalSince($0) / 86_400) + 1, 2), 14) } ?? 7
        let ids = try await api.listMessageIDs(query: Self.query(days: days), max: 40)
        let newIDs = ids.filter { !AnalyzedLog.charges.contains($0) }
        guard !newIDs.isEmpty else { return Summary(date: .now) }

        let messages = try await withThrowingTaskGroup(of: InboxMessage?.self) { group in
            for id in newIDs { group.addTask { try await api.message(id: id) } }
            var result: [InboxMessage] = []
            for try await message in group { if let message { result.append(message) } }
            return result
        }

        let expense = LedgerStore.activeCategories(kind: .expense)
        let income = LedgerStore.activeCategories(kind: .income)
        let results = try await client.charges(
            messages,
            expense: expense.map { .init(id: $0.slug, name: $0.name) },
            income: income.map { .init(id: $0.slug, name: $0.name) },
            currencyHint: LedgerSettings.lastCurrency
        )
        AnalyzedLog.charges.insert(newIDs)

        let receivedAt = Dictionary(messages.map { ($0.id, $0.receivedAt) }, uniquingKeysWith: { a, _ in a })
        let candidates = results.compactMap { Self.candidate(from: $0, receivedAt: receivedAt[$0.sourceId], incomeSlugs: Set(income.map(\.slug))) }
        return await insert(candidates)
    }

    // MARK: - 写入账本

    struct Candidate: Equatable {
        var kind: LedgerKind
        var amount: Decimal
        var currency: Currency
        var merchant: String
        var date: Date
        var categoryID: String
        var note: String
        var externalID: String
    }

    /// 已有记录里用来比对的部分
    struct ExistingEntry: Equatable {
        var kind: LedgerKind
        var amount: Decimal
        var currency: Currency
        var merchant: String
        var date: Date
    }

    nonisolated static func candidate(from c: DSAClient.ChargeResult, receivedAt: Date?, incomeSlugs: Set<String>) -> Candidate? {
        guard let currency = Currency(rawValue: c.currency.uppercased()), c.amount > 0,
              let amount = Decimal(string: String(format: "%.\(currency.fractionDigits)f", c.amount)) else { return nil }
        let kind: LedgerKind = c.kind == "refund" ? .income : .expense
        let date = c.date.flatMap { ReceiptScanner.parseDate($0) } ?? receivedAt ?? .now
        var category = c.categoryId
        if kind == .income {
            if !incomeSlugs.contains(category) { category = "refund" }
        } else if let remembered = MerchantMemory.category(for: c.merchant) {
            // 用户改过的分类优先
            category = remembered
        }
        return Candidate(
            kind: kind, amount: amount, currency: currency, merchant: c.merchant,
            date: date, categoryID: category, note: c.note, externalID: "email:\(c.externalId)"
        )
    }

    /// 同方向、同币种、同金额、前后 2 天内、商家名对得上，就认为是同一笔（比如 Apple Pay 已经记过）
    nonisolated static func isDuplicate(_ c: Candidate, of existing: [ExistingEntry]) -> Bool {
        let name = MerchantMemory.normalize(c.merchant)
        return existing.contains { e in
            guard e.kind == c.kind, e.currency == c.currency,
                  abs(NSDecimalNumber(decimal: e.amount - c.amount).doubleValue) < 0.005,
                  abs(e.date.timeIntervalSince(c.date)) <= 2 * 86_400 else { return false }
            let other = MerchantMemory.normalize(e.merchant)
            guard !name.isEmpty, !other.isEmpty else { return false }
            return name == other || name.hasPrefix(other) || other.hasPrefix(name)
        }
    }

    private func insert(_ candidates: [Candidate]) async -> Summary {
        var summary = Summary(date: .now)
        guard let earliest = candidates.map(\.date).min(), let latest = candidates.map(\.date).max() else { return summary }

        let from = earliest.addingTimeInterval(-3 * 86_400)
        let to = latest.addingTimeInterval(3 * 86_400)
        let descriptor = FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.date >= from && $0.date <= to })
        var existing = ((try? LedgerStore.context.fetch(descriptor)) ?? []).map {
            ExistingEntry(kind: $0.kind, amount: $0.amount, currency: $0.currencyValue, merchant: $0.merchant, date: $0.date)
        }

        for c in candidates {
            if LedgerStore.exists(externalID: c.externalID) || Self.isDuplicate(c, of: existing) {
                summary.duplicates += 1
                continue
            }
            let entry = await LedgerStore.add(
                kind: c.kind, amount: c.amount, currency: c.currency, categoryID: c.categoryID,
                merchant: c.merchant, note: c.note, date: c.date, source: .email, externalID: c.externalID
            )
            if entry != nil {
                summary.added.append(c.merchant)
                existing.append(ExistingEntry(kind: c.kind, amount: c.amount, currency: c.currency, merchant: c.merchant, date: c.date))
            }
        }
        return summary
    }

    /// Gmail 搜索条件：付款、收据、订阅、退款相关的中英文关键词（包括被分到推广 / 更新里的）
    nonisolated static func query(days: Int) -> String {
        let words = [
            "receipt", "invoice", "\"tax invoice\"", "\"payment received\"", "\"payment confirmation\"",
            "\"payment successful\"", "\"order confirmation\"", "\"your order\"", "renewal", "renewed",
            "subscription", "\"direct debit\"", "\"auto top\"", "\"top up\"", "charged", "billed", "refund",
            "收据", "发票", "扣费", "扣款", "支付成功", "付款成功", "账单", "订阅", "续费", "退款",
        ]
        return "newer_than:\(days)d (\(words.joined(separator: " OR "))) -in:spam -in:trash"
    }
}
