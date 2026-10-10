import CryptoKit
import Foundation

/// CSV 里识别出来的一笔
struct CSVTransaction: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case new
        /// 以前导入过同一行（externalID 已存在）
        case imported
        /// 金额、日期、商家和已有的一笔对得上（比如 Apple Pay 已经记过）
        case likelyDuplicate
    }

    let id: Int
    var date: Date
    var kind: LedgerKind
    /// 正数
    var amount: Decimal
    /// 文件里写明的币种；nil 表示跟随整个文件的币种
    var currency: Currency?
    /// 收支是按金额正负号判断的（整体反转时只翻这些）
    var signBased: Bool
    /// 原始描述（去掉了 Value Date、卡号），交给 Claude 分类用
    var rawDescription: String
    var merchant: String
    var note: String
    var categoryID: String = ""
    var externalID: String
    var status: Status = .new
    var include = true
}

/// 整个文件的识别结果
struct CSVStatement: Sendable {
    /// "CommBank" / "支付宝" / "微信支付" / "银行流水"
    var format: String
    /// 没写币种的行用这个
    var defaultCurrency: Currency
    var transactions: [CSVTransaction]
    /// 不计收支、交易关闭、金额为 0 等跳过的行数
    var skipped: Int
}

/// 银行 / 信用卡 / 支付宝 / 微信导出的 CSV → 一笔笔账。
/// 全部在本地解析；只有商家名会发给 Worker 让 Claude 分类
enum CSVImporter {
    enum ImportError: LocalizedError {
        case unreadable
        case unrecognized
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "文件读取失败，请确认是 CSV 文本文件"
            case .unrecognized: "没认出日期和金额列。支持 CommBank、Westpac、NAB、ANZ、ING、Up、支付宝等导出的 CSV"
            case .empty: "文件里没有可以导入的交易"
            }
        }
    }

    // MARK: - 入口

    static func parse(_ data: Data, calendar: Calendar = .current) throws -> CSVStatement {
        guard let text = decode(data) else { throw ImportError.unreadable }
        let rows = parseRows(text)
        guard !rows.isEmpty else { throw ImportError.empty }

        let headerIndex = rows.prefix(40).firstIndex { headerColumns($0).isValid }
        let columns: Columns
        let body: ArraySlice<[String]>
        if let headerIndex {
            columns = headerColumns(rows[headerIndex])
            body = rows[(headerIndex + 1)...]
        } else if let inferred = inferColumns(rows) {
            columns = inferred
            body = rows[...]
        } else {
            throw ImportError.unrecognized
        }

        let format = detectFormat(text: text, header: headerIndex.map { rows[$0] }, body: body)
        let defaultCurrency = columns.amountCurrency ?? (format == "支付宝" || format == "微信支付" ? .CNY : .base)
        let dates = DateParser(samples: body.compactMap { columns.date.flatMap($0.cell) })
        // 支付宝 / 微信：交易对方是商家，商品说明放备注；银行流水的描述太长，不放备注
        let descriptionAsNote = format == "支付宝" || format == "微信支付"

        var transactions: [CSVTransaction] = []
        var skipped = 0
        var occurrences: [String: Int] = [:]

        for row in body {
            // 页脚、说明文字、空行：日期都解析不出来，直接忽略
            guard let dateText = columns.date.flatMap(row.cell), var date = dates.parse(dateText, calendar: calendar) else { continue }

            if let status = columns.status.flatMap(row.cell)?.lowercased(),
               ["关闭", "失败", "撤销", "全额退款", "fail", "declin", "cancel", "revers"].contains(where: status.contains) {
                skipped += 1
                continue
            }
            guard let (kind, amount, signBased) = amountAndKind(row, columns) else {
                skipped += 1
                continue
            }

            var description = columns.description.flatMap(row.cell) ?? ""
            // CommBank 的日期是入账日，描述里的 Value Date 才是真正刷卡那天（和 Apple Pay 记的对得上）
            if let valueDate = valueDate(in: description, calendar: calendar),
               let days = calendar.dateComponents([.day], from: valueDate, to: date).day, (0...10).contains(days) {
                date = valueDate
            }
            description = cleanDescription(description)

            var merchant = columns.merchant.flatMap(row.cell).map(cleanDescription) ?? ""
            var note = columns.note.flatMap(row.cell) ?? ""
            if merchant.isEmpty || merchant == "/" {
                merchant = description
            } else if descriptionAsNote, description != merchant, description != "/" {
                note = [description, note].filter { !$0.isEmpty && $0 != "/" }.joined(separator: " · ")
            }
            if note == "/" { note = "" }
            guard !merchant.isEmpty else {
                skipped += 1
                continue
            }

            let currency = columns.currency.flatMap(row.cell).flatMap { Currency(rawValue: $0.uppercased()) }
                ?? columns.amountCurrency
            let externalID: String
            if let reference = columns.reference.flatMap(row.cell), !reference.isEmpty, reference != "/" {
                externalID = "csv:\(reference)"
            } else {
                // 同一天、同金额、同描述的两笔（比如两杯一样的咖啡）用出现次序区分
                let key = "\(dayKey(date, calendar: calendar))|\(kind.rawValue)|\(amount)|\(description.lowercased())"
                let n = occurrences[key, default: 0]
                occurrences[key] = n + 1
                externalID = "csv:" + stableHash("\(key)|\(n)")
            }

            transactions.append(CSVTransaction(
                id: transactions.count, date: date, kind: kind, amount: amount, currency: currency,
                signBased: signBased, rawDescription: description, merchant: String(merchant.prefix(60)),
                note: String(note.prefix(80)), externalID: externalID
            ))
        }

        guard !transactions.isEmpty else { throw ImportError.empty }
        transactions = applySignConvention(transactions)
        return CSVStatement(
            format: format,
            defaultCurrency: defaultCurrency,
            transactions: transactions.sorted { $0.date > $1.date },
            skipped: skipped
        )
    }

    /// 收支反过来（只翻按正负号判断的行）
    static func flipSigns(_ transactions: [CSVTransaction]) -> [CSVTransaction] {
        transactions.map { t in
            guard t.signBased else { return t }
            var t = t
            t.kind = t.kind == .expense ? .income : .expense
            return t
        }
    }

    // MARK: - 编码与拆行

    /// UTF-8（含 BOM）→ UTF-16（Excel「Unicode 文本」）→ GB18030（支付宝、微信导出）
    static func decode(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(3))
        var text: String?
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            text = String(data: data, encoding: .utf16)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            text = String(data: data, encoding: String.Encoding(rawValue: gb)) ?? String(data: data, encoding: .isoLatin1)
        }
        guard var text else { return nil }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        return text
    }

    /// RFC 4180：引号里的逗号、换行、两个引号转义。分隔符自动识别（逗号 / 分号 / 制表符）
    static func parseRows(_ text: String) -> [[String]] {
        let delimiter = detectDelimiter(text)
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func endField() {
            row.append(String(field).trimmingCharacters(in: .whitespacesAndNewlines))
            field = String.UnicodeScalarView()
        }
        func endRow() {
            endField()
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
        }

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                endField()
            } else if c == "\n" || c == "\r" {
                endRow()
                if c == "\r", i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    private static func detectDelimiter(_ text: String) -> Unicode.Scalar {
        let sample = text.split(whereSeparator: \.isNewline).prefix(30).joined(separator: "\n")
        let candidates: [Unicode.Scalar] = [",", "\t", ";"]
        return candidates.max { a, b in
            sample.unicodeScalars.count { $0 == a } < sample.unicodeScalars.count { $0 == b }
        } ?? ","
    }

    // MARK: - 列识别

    struct Columns: Equatable {
        var date: Int?
        var amount: Int?
        var debit: Int?
        var credit: Int?
        /// 支付宝 / 微信的「收/支」
        var direction: Int?
        var merchant: Int?
        var description: Int?
        var note: Int?
        var currency: Int?
        var status: Int?
        var reference: Int?
        /// 金额列标题里写的币种，比如 "Amount (AUD)"、"金额(元)"
        var amountCurrency: Currency?

        var isValid: Bool { date != nil && (amount != nil || debit != nil || credit != nil) }
    }

    enum Role { case balance, date, direction, debit, credit, amount, reference, status, merchant, description, note, currency }

    /// 标题 → 这一列是什么。顺序有讲究：Value Date 先算日期，Debit Amount 先算支出，对方账号不算商家
    static func role(forHeader raw: String) -> Role? {
        let h = raw.lowercased()
        func has(_ words: String...) -> Bool { words.contains { h.contains($0) } }
        guard !h.isEmpty else { return nil }
        if has("balance", "余额") { return .balance }
        if has("date", "time", "日期", "时间") { return .date }
        if has("收/支", "收支", "dr/cr", "debit/credit", "in/out") { return .direction }
        if has("debit", "withdrawal", "money out", "paid out", "outflow", "支出") { return .debit }
        if has("credit", "deposit", "money in", "paid in", "inflow", "存入", "收入") { return .credit }
        if has("amount", "金额", "subtotal", "total", "value") { return .amount }
        if has("订单号", "单号", "流水号", "transaction id", "reference", "receipt") { return .reference }
        if has("账号", "account", "卡号", "bsb") { return nil }
        if has("状态", "status") { return .status }
        if has("merchant", "payee", "交易对方", "对方", "收款方", "商户名称", "counterparty") { return .merchant }
        if has("description", "narrative", "details", "particulars", "说明", "摘要", "描述", "商品") { return .description }
        if has("备注", "note", "memo", "comment", "remark") { return .note }
        if has("currency", "币种", "货币") { return .currency }
        return nil
    }

    static func headerColumns(_ header: [String]) -> Columns {
        var c = Columns()
        for (index, title) in header.enumerated() {
            switch role(forHeader: title) {
            case .date: c.date = c.date ?? index
            case .direction: c.direction = c.direction ?? index
            case .debit: c.debit = c.debit ?? index
            case .credit: c.credit = c.credit ?? index
            case .amount:
                if c.amount == nil {
                    c.amount = index
                    c.amountCurrency = currency(inHeader: title)
                }
            case .reference: c.reference = c.reference ?? index
            case .status: c.status = c.status ?? index
            case .merchant: c.merchant = c.merchant ?? index
            case .description: c.description = c.description ?? index
            case .note: c.note = c.note ?? index
            case .currency: c.currency = c.currency ?? index
            case .balance, nil: break
            }
        }
        // 含日期的是数据行（比如描述里正好有 "Value Date"），不是标题行
        guard c.isValid, !header.contains(where: DateParser.looksLikeDate) else { return Columns() }
        return c
    }

    /// 没有标题行（CommBank、ANZ）：日期 | 金额 | 描述 | 余额
    static func inferColumns(_ rows: [[String]]) -> Columns? {
        let sample = Array(rows.prefix(60))
        let width = sample.map(\.count).max() ?? 0
        guard width >= 2 else { return nil }

        func ratio(_ column: Int, _ test: (String) -> Bool) -> Double {
            let values = sample.compactMap { $0.cell(column) }
            guard !values.isEmpty else { return 0 }
            return Double(values.filter(test).count) / Double(values.count)
        }

        guard let date = (0..<width).first(where: { ratio($0, DateParser.looksLikeDate) >= 0.8 }) else { return nil }
        let numeric = (0..<width).filter { $0 != date && ratio($0, { parseAmount($0) != nil }) >= 0.8 }
        guard let amount = numeric.first else { return nil }
        let description = (0..<width)
            .filter { $0 != date && !numeric.contains($0) }
            .max { a, b in
                sample.reduce(0) { $0 + ($1.cell(a)?.count ?? 0) } < sample.reduce(0) { $0 + ($1.cell(b)?.count ?? 0) }
            }
        return Columns(date: date, amount: amount, description: description)
    }

    private static func currency(inHeader title: String) -> Currency? {
        if title.contains("元") || title.contains("¥") || title.contains("￥") { return .CNY }
        let upper = title.uppercased()
        return Currency.allCases.first { upper.contains("(\($0.rawValue))") || upper.contains("（\($0.rawValue)）") }
    }

    private static func detectFormat(text: String, header: [String]?, body: ArraySlice<[String]>) -> String {
        let head = String(text.prefix(2000))
        let titles = header?.joined(separator: ",") ?? ""
        if head.contains("支付宝") || (titles.contains("交易对方") && titles.contains("商品说明")) { return "支付宝" }
        if head.contains("微信支付") || (titles.contains("交易单号") && titles.contains("当前状态")) { return "微信支付" }
        if header == nil, body.contains(where: { $0.joined().contains("Value Date") }) || (body.first?.count ?? 0) == 4 {
            return "CommBank"
        }
        return "银行流水"
    }

    // MARK: - 金额与收支

    /// 一行的收支方向和金额（正数）。signBased = 按正负号判断的
    private static func amountAndKind(_ row: [String], _ c: Columns) -> (LedgerKind, Decimal, Bool)? {
        if c.debit != nil || c.credit != nil {
            if let debit = c.debit.flatMap(row.cell).flatMap(parseAmount), debit != 0 { return (.expense, abs(debit), false) }
            if let credit = c.credit.flatMap(row.cell).flatMap(parseAmount), credit != 0 { return (.income, abs(credit), false) }
            // Westpac 之类也可能同时有一个带正负号的金额列
            guard c.amount == nil else { return signed(row, c) }
            return nil
        }
        if let direction = c.direction.flatMap(row.cell)?.lowercased(), !direction.isEmpty, direction != "/" {
            guard let value = c.amount.flatMap(row.cell).flatMap(parseAmount), value != 0 else { return nil }
            if direction.contains("支出") || direction.hasPrefix("d") || direction.contains("out") { return (.expense, abs(value), false) }
            if direction.contains("收入") || direction.hasPrefix("c") || direction.contains("in") { return (.income, abs(value), false) }
            // 「不计收支」：余额宝转入转出、还信用卡这类自己账户之间的钱
            return nil
        }
        if c.direction != nil { return nil }
        return signed(row, c)
    }

    private static func signed(_ row: [String], _ c: Columns) -> (LedgerKind, Decimal, Bool)? {
        guard let value = c.amount.flatMap(row.cell).flatMap(parseAmount), value != 0 else { return nil }
        return (value < 0 ? .expense : .income, abs(value), true)
    }

    /// 银行账户：花钱是负数（大多数行）；信用卡：花钱是正数。按多数行的符号判断，多数那一边算支出
    private static func applySignConvention(_ transactions: [CSVTransaction]) -> [CSVTransaction] {
        let signed = transactions.filter(\.signBased)
        let positives = signed.count { $0.kind == .income }
        return positives > signed.count - positives ? flipSigns(transactions) : transactions
    }

    /// "-12.50"、"$1,234.56"、"(12.50)"、"12.50 DR"、"¥8.00"、"AUD 12.50" → 带符号的数
    static func parseAmount(_ raw: String) -> Decimal? {
        var s = raw.replacingOccurrences(of: "[\\s\u{00A0}]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "−", with: "-")
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("("), s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        let upper = s.uppercased()
        if upper.hasSuffix("DR") {
            negative.toggle()
            s.removeLast(2)
        } else if upper.hasSuffix("CR") {
            s.removeLast(2)
        }
        s = s.replacingOccurrences(of: "^[A-Za-z]{3}|[A-Za-z]{3}$|元$|^[A-Za-z]{0,2}\\$|[$¥￥€£₩]", with: "", options: .regularExpression)
        if s.hasPrefix("-") {
            negative.toggle()
            s.removeFirst()
        } else if s.hasPrefix("+") {
            s.removeFirst()
        }
        s = s.replacingOccurrences(of: "^[A-Za-z]{0,2}\\$|[$¥￥€£₩]", with: "", options: .regularExpression)
        guard s.range(of: "^(\\d{1,3}(,\\d{3})+|\\d+)?(\\.\\d+)?$", options: .regularExpression) != nil,
              s.contains(where: \.isNumber),
              let value = Decimal(string: s.replacingOccurrences(of: ",", with: ""), locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return negative ? -value : value
    }

    // MARK: - 描述

    /// "Value Date: 29/09/2026"
    private static func valueDate(in description: String, calendar: Calendar) -> Date? {
        guard let range = description.range(of: "(?i)value date:?\\s*\\d{1,2}/\\d{1,2}/\\d{2,4}", options: .regularExpression) else { return nil }
        let text = description[range].replacingOccurrences(of: "(?i)value date:?\\s*", with: "", options: .regularExpression)
        return DateParser(dayFirst: true).parse(text, calendar: calendar)
    }

    /// 去掉 CommBank 描述里的 Value Date、卡号，合并空格
    static func cleanDescription(_ raw: String) -> String {
        raw.replacingOccurrences(of: "(?i)\\s*value date:?\\s*\\d{1,2}/\\d{1,2}/\\d{2,4}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?i)\\s*card\\s+x+\\d+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    private static func stableHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 日期

/// 自动判断 日/月/年 还是 月/日/年：出现大于 12 的那一位就是「日」；都判断不了按澳洲习惯（日在前）
struct DateParser {
    var dayFirst = true
    /// 2026-10-02、02/10/2026、2026/9/30 18:20、2026年10月2日
    private let numeric = try! Regex("^(\\d{1,4})[/.\\-年](\\d{1,2})[/.\\-月](\\d{1,4})日?(?:[ T]+(\\d{1,2}):(\\d{2})(?::(\\d{2}))?)?")

    init(dayFirst: Bool) {
        self.dayFirst = dayFirst
    }

    init(samples: [String]) {
        for sample in samples.prefix(200) {
            guard let match = sample.trimmingCharacters(in: .whitespaces).firstMatch(of: numeric),
                  let a = match.output[1].substring.flatMap({ Int($0) }),
                  let b = match.output[2].substring.flatMap({ Int($0) }), a <= 31 else { continue }
            if a > 12 { dayFirst = true; break }
            if b > 12 { dayFirst = false; break }
        }
    }

    static func looksLikeDate(_ text: String) -> Bool {
        DateParser(dayFirst: true).parse(text, calendar: Calendar(identifier: .gregorian)) != nil
    }

    /// 只有日期没有时间的，记在当天中午
    func parse(_ raw: String, calendar: Calendar) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.count >= 6, text.first?.isNumber == true || text.first?.isLetter == true else { return nil }

        if text.contains("T"), text.hasSuffix("Z") || text.range(of: "[+-]\\d{2}:?\\d{2}$", options: .regularExpression) != nil {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: text) { return date }
            iso.formatOptions.insert(.withFractionalSeconds)
            if let date = iso.date(from: text) { return date }
        }

        if let match = text.firstMatch(of: numeric) {
            let n = (1...6).map { match.output[$0].substring.flatMap { Int($0) } }
            guard let a = n[0], let b = n[1], let c = n[2] else { return nil }
            let (year, month, day): (Int, Int, Int) =
                a > 31 ? (a, b, c) : dayFirst ? (c, b, a) : (c, a, b)
            return make(year: year < 100 ? 2000 + year : year, month: month, day: day, hour: n[3], minute: n[4], second: n[5], calendar: calendar)
        }

        // "02 Oct 2026"、"2 October 2026"、"Oct 2, 2026"、"02-Oct-26"
        guard text.count <= 24, text.contains(where: \.isLetter), text.contains(where: \.isNumber) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.isLenient = false
        for format in ["d MMM yyyy", "d MMMM yyyy", "d MMM yy", "d-MMM-yyyy", "d-MMM-yy", "MMM d, yyyy", "MMMM d, yyyy", "d MMM yyyy HH:mm"] {
            f.dateFormat = format
            if let date = f.date(from: text) {
                let hasTime = format.contains("HH")
                return hasTime ? date : calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date)
            }
        }
        return nil
    }

    private func make(year: Int, month: Int, day: Int, hour: Int?, minute: Int?, second: Int?, calendar: Calendar) -> Date? {
        guard (1990...2100).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var components = DateComponents(year: year, month: month, day: day, hour: hour ?? 12, minute: minute ?? 0, second: second ?? 0)
        components.calendar = calendar
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day else { return nil }
        return date
    }
}

extension [String] {
    /// 越界或空字符串返回 nil
    func cell(_ index: Int) -> String? {
        guard indices.contains(index) else { return nil }
        let value = self[index]
        return value.isEmpty ? nil : value
    }
}
