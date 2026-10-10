import AppIntents
import Foundation
import SwiftData

// QuickAddIntent、CaptureReceiptIntent 在 Shared/SharedIntents.swift（app 和扩展共用）

// MARK: - 不打开 app 记一笔支出（Siri 问金额和分类）

struct LogExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "记一笔支出"
    static let description = IntentDescription("不用打开 DSA，直接记一笔支出")

    @Parameter(title: "金额", requestValueDialog: "花了多少钱？")
    var amount: Double

    @Parameter(title: "分类", requestValueDialog: "记在哪个分类？")
    var category: LedgerCategoryEntity

    @Parameter(title: "商家")
    var merchant: String?

    @Parameter(title: "币种")
    var currency: Currency?

    static var parameterSummary: some ParameterSummary {
        Summary("记 \(\.$amount) 到 \(\.$category)") {
            \.$merchant
            \.$currency
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let currency = currency ?? LedgerSettings.lastCurrency
        guard amount > 0, let decimal = Decimal(string: String(format: "%.\(currency.fractionDigits)f", amount)) else {
            throw $amount.needsValueError("金额要大于 0")
        }
        await LedgerStore.add(
            amount: decimal, currency: currency, categoryID: category.id,
            merchant: merchant ?? "", source: .shortcut
        )
        return .result(dialog: "已记录 \(Money.format(amount, currency)) · \(category.name)")
    }
}

// MARK: - Apple Pay 自动记账（快捷指令「Wallet 交易」自动化调用）

struct LogTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "记录 Apple Pay 交易"
    static let description = IntentDescription("给快捷指令的「钱包 / Wallet」自动化用：传入金额和商家，DSA 自动分类并记账")

    @Parameter(title: "金额")
    var amount: Double

    @Parameter(title: "商家")
    var merchant: String

    @Parameter(title: "币种代码", description: "例如 AUD、CNY，不填默认 AUD")
    var currencyCode: String?

    @Parameter(title: "卡片")
    var card: String?

    static var parameterSummary: some ParameterSummary {
        Summary("记录 \(\.$merchant) 的 \(\.$amount)") {
            \.$currencyCode
            \.$card
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let value = abs(amount)
        let currency = currencyCode.flatMap { Currency(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased()) } ?? .base
        guard value > 0, let decimal = Decimal(string: String(format: "%.\(currency.fractionDigits)f", value)) else {
            return .result(dialog: "金额为 0，没有记账")
        }

        let (categoryID, cleanMerchant) = await LedgerStore.classify(merchant: merchant, amount: value)
        // 同一分钟、同商家、同金额只记一次（防止自动化重复触发）
        let minute = Int(Date.now.timeIntervalSince1970 / 60)
        let externalID = "applepay:\(MerchantMemory.normalize(merchant)):\(decimal):\(minute)"

        let entry = await LedgerStore.add(
            amount: decimal, currency: currency, categoryID: categoryID,
            merchant: cleanMerchant, note: card ?? "", source: .applePay, externalID: externalID
        )
        guard entry != nil else { return .result(dialog: "这笔已经记过了") }
        let categoryName = LedgerStore.category(slug: categoryID)?.name ?? "其他"
        return .result(dialog: "已记录 \(Money.format(value, currency)) · \(cleanMerchant) · \(categoryName)")
    }
}

// MARK: - 分类实体（让 Siri / 快捷指令能选分类）

struct LedgerCategoryEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "分类"
    static let defaultQuery = LedgerCategoryQuery()

    var id: String
    var name: String
    var symbol: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: symbol))
    }
}

struct LedgerCategoryQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [LedgerCategoryEntity.ID]) async throws -> [LedgerCategoryEntity] {
        LedgerStore.activeCategories(kind: .expense)
            .filter { identifiers.contains($0.slug) }
            .map(\.entity)
    }

    @MainActor
    func suggestedEntities() async throws -> [LedgerCategoryEntity] {
        LedgerStore.activeCategories(kind: .expense).map(\.entity)
    }
}

extension LedgerCategory {
    var entity: LedgerCategoryEntity { LedgerCategoryEntity(id: slug, name: name, symbol: symbol) }
}

// MARK: - 币种

extension Currency: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "币种" }

    // App Intents 的元数据工具要求这里是字面量字典
    static var caseDisplayRepresentations: [Currency: DisplayRepresentation] {
        [
            .AUD: "AUD 澳元", .CNY: "CNY 人民币", .USD: "USD 美元", .EUR: "EUR 欧元",
            .GBP: "GBP 英镑", .JPY: "JPY 日元", .HKD: "HKD 港币", .NZD: "NZD 新西兰元",
            .SGD: "SGD 新加坡元", .CAD: "CAD 加元", .KRW: "KRW 韩元",
        ]
    }
}

// MARK: - Siri 短语 / 操作按钮里显示的快捷方式

struct DSAShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickAddIntent(),
            phrases: [
                "\(.applicationName)记一笔",
                "用\(.applicationName)记账",
                "Add expense in \(.applicationName)",
            ],
            shortTitle: "记一笔",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: LogExpenseIntent(),
            phrases: [
                "用\(.applicationName)记一笔支出",
                "Log expense with \(.applicationName)",
            ],
            shortTitle: "记一笔支出",
            systemImageName: "creditcard"
        )
    }
}
