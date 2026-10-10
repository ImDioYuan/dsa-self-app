import Foundation
import SwiftData

/// 收入还是支出
enum LedgerKind: String, Codable, CaseIterable, Sendable {
    case expense, income

    var displayName: String {
        switch self {
        case .expense: "支出"
        case .income: "收入"
        }
    }
}

/// 这笔账是怎么记进来的
enum EntrySource: String, Codable, CaseIterable, Sendable {
    case manual, receipt, applePay, csv, shortcut, email

    var displayName: String {
        switch self {
        case .manual: "手动"
        case .receipt: "小票"
        case .applePay: "Apple Pay"
        case .csv: "CSV"
        case .shortcut: "快捷指令"
        case .email: "邮件"
        }
    }
}

/// 一笔账。金额按原币种保存，同时记下当天对 AUD 的汇率，统计时统一换算。
/// 所有属性都有默认值，以后可以打开 CloudKit 同步。
@Model
final class LedgerEntry {
    var kindRaw: String = LedgerKind.expense.rawValue
    var amount: Decimal = 0
    var currency: String = Currency.base.rawValue
    /// 1 单位原币种 = 多少 AUD（记账当天的汇率）
    var rateToBase: Double = 1
    var categoryID: String = ""
    var merchant: String = ""
    var note: String = ""
    var date: Date = Date.now
    var sourceRaw: String = EntrySource.manual.rawValue
    /// 外部来源的唯一标识（CSV 行、Apple Pay 交易），用来去重
    var externalID: String?
    @Attribute(.externalStorage) var receiptImage: Data?
    var createdAt: Date = Date.now

    init(
        kind: LedgerKind,
        amount: Decimal,
        currency: Currency,
        rateToBase: Double,
        categoryID: String,
        merchant: String = "",
        note: String = "",
        date: Date = .now,
        source: EntrySource = .manual,
        externalID: String? = nil
    ) {
        kindRaw = kind.rawValue
        self.amount = amount
        self.currency = currency.rawValue
        self.rateToBase = rateToBase
        self.categoryID = categoryID
        self.merchant = merchant
        self.note = note
        self.date = date
        sourceRaw = source.rawValue
        self.externalID = externalID
        createdAt = .now
    }

    var kind: LedgerKind {
        get { LedgerKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var source: EntrySource { EntrySource(rawValue: sourceRaw) ?? .manual }
    var currencyValue: Currency { Currency(rawValue: currency) ?? .base }

    /// 换算成 AUD 的金额
    var baseAmount: Double { NSDecimalNumber(decimal: amount).doubleValue * rateToBase }

    /// 统计用的值类型
    var value: EntryValue {
        EntryValue(kind: kind, baseAmount: baseAmount, categoryID: categoryID, date: date)
    }
}
