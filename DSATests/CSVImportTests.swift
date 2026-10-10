import Foundation
import Testing
@testable import DSA

@Suite("CSV 导入")
struct CSVImportTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }()

    private func day(_ date: Date) -> DateComponents {
        calendar.dateComponents([.year, .month, .day], from: date)
    }

    @Test func commBankWithoutHeader() throws {
        let csv = """
        "01/10/2026","-12.50","WOOLWORTHS 1234 SYDNEY AU Card xx1234 Value Date: 29/09/2026","+1234.56"
        "30/09/2026","+850.00","Salary ACME PTY LTD","+1247.06"
        "30/09/2026","-4.20","TRANSPORTFORNSW OPAL SYDNEY AU Card xx1234 Value Date: 28/09/2026","+397.06"
        "29/09/2026","0.00","Interest","+401.26"
        """
        let s = try CSVImporter.parse(Data(csv.utf8), calendar: calendar)
        #expect(s.format == "CommBank")
        #expect(s.defaultCurrency == .AUD)
        #expect(s.transactions.count == 3)
        #expect(s.skipped == 1)

        let woolies = try #require(s.transactions.first { $0.rawDescription.hasPrefix("WOOLWORTHS") })
        #expect(woolies.kind == .expense)
        #expect(woolies.amount == Decimal(string: "12.50"))
        // 用 Value Date（刷卡那天），去掉卡号和 Value Date
        #expect(day(woolies.date) == DateComponents(year: 2026, month: 9, day: 29))
        #expect(woolies.rawDescription == "WOOLWORTHS 1234 SYDNEY AU")

        let salary = try #require(s.transactions.first { $0.rawDescription.hasPrefix("Salary") })
        #expect(salary.kind == .income)
        #expect(salary.signBased)
    }

    @Test func sameFileGivesSameIDs() throws {
        let csv = """
        02/10/2026,-5.00,CAMPUS CAFE
        02/10/2026,-5.00,CAMPUS CAFE
        """
        let a = try CSVImporter.parse(Data(csv.utf8), calendar: calendar)
        let b = try CSVImporter.parse(Data(csv.utf8), calendar: calendar)
        // 两杯一样的咖啡是两笔，但重新导入同一个文件得到同样的 id
        #expect(Set(a.transactions.map(\.externalID)).count == 2)
        #expect(Set(a.transactions.map(\.externalID)) == Set(b.transactions.map(\.externalID)))
    }

    @Test func alipayGBK() throws {
        let csv = """
        支付宝交易明细
        起始时间：[2026-09-01 00:00:00]    终止时间：[2026-09-30 23:59:59]
        ------------------------支付宝（中国）网络技术有限公司  电子客户回单------------------------
        交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注,
        2026-09-30 18:20:11,餐饮美食,美团,/,美团外卖订单,支出,35.80,余额宝,交易成功,2026093022001\t,T123\t,,
        2026-09-29 09:00:00,投资理财,余额宝,/,余额宝-转入,不计收支,500.00,账户余额,交易成功,2026092922002\t,,,
        2026-09-28 12:00:00,日用百货,淘宝店铺,/,数据线,支出,19.90,花呗,交易关闭,2026092822003\t,,,
        2026-09-27 08:30:00,转账红包,张三,138****0000,转账,收入,200.00,,交易成功,2026092722004\t,,,
        """
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        let data = try #require(csv.data(using: String.Encoding(rawValue: gb)))
        let s = try CSVImporter.parse(data, calendar: calendar)

        #expect(s.format == "支付宝")
        #expect(s.defaultCurrency == .CNY)
        #expect(s.transactions.count == 2)
        #expect(s.skipped == 2)

        let meituan = try #require(s.transactions.first { $0.merchant == "美团" })
        #expect(meituan.kind == .expense)
        #expect(meituan.amount == Decimal(string: "35.80"))
        #expect(meituan.note == "美团外卖订单")
        #expect(meituan.externalID == "csv:2026093022001")
        #expect(calendar.component(.hour, from: meituan.date) == 18)
        #expect(s.transactions.first { $0.merchant == "张三" }?.kind == .income)
    }

    @Test func westpacDebitCredit() throws {
        let csv = """
        Bank Account,Date,Narrative,Debit Amount,Credit Amount,Balance,Categories,Serial
        032000123456,02/10/2026,EFTPOS PURCHASE WOOLWORTHS 1234,45.10,,900.00,GROCERIES,
        032000123456,01/10/2026,DEPOSIT ONLINE FROM DAD,,500.00,945.10,TFR,
        """
        let s = try CSVImporter.parse(Data(csv.utf8), calendar: calendar)
        #expect(s.format == "银行流水")
        #expect(s.transactions.map(\.kind) == [.expense, .income])
        #expect(s.transactions.allSatisfy { !$0.signBased })
        #expect(s.transactions[0].amount == Decimal(string: "45.10"))
    }

    @Test func creditCardPositiveMeansSpending() throws {
        // 信用卡导出：消费是正数，还款是负数
        let csv = """
        Transaction Date,Description,Amount (USD)
        10/01/2026,Apple Services,9.99
        10/02/2026,Amazon,25.00
        10/15/2026,Payment Thank You,-34.99
        """
        let s = try CSVImporter.parse(Data(csv.utf8), calendar: calendar)
        #expect(s.defaultCurrency == .USD)
        #expect(s.transactions.first { $0.merchant == "Amazon" }?.kind == .expense)
        #expect(s.transactions.first { $0.merchant.hasPrefix("Payment") }?.kind == .income)
        // 10/15 只能是 月/日
        let payment = try #require(s.transactions.first { $0.merchant.hasPrefix("Payment") })
        #expect(day(payment.date) == DateComponents(year: 2026, month: 10, day: 15))

        let flipped = CSVImporter.flipSigns(s.transactions)
        #expect(flipped.first { $0.merchant == "Amazon" }?.kind == .income)
    }

    @Test func amounts() {
        #expect(CSVImporter.parseAmount("-12.50") == Decimal(string: "-12.50"))
        #expect(CSVImporter.parseAmount("$1,234.56") == Decimal(string: "1234.56"))
        #expect(CSVImporter.parseAmount("-$8.00") == -8)
        #expect(CSVImporter.parseAmount("(12.00)") == -12)
        #expect(CSVImporter.parseAmount("12.00 DR") == -12)
        #expect(CSVImporter.parseAmount("¥8.80") == Decimal(string: "8.80"))
        #expect(CSVImporter.parseAmount("A$5") == 5)
        #expect(CSVImporter.parseAmount("+850.00") == 850)
        #expect(CSVImporter.parseAmount("7-Eleven") == nil)
        #expect(CSVImporter.parseAmount("Transfer") == nil)
        #expect(CSVImporter.parseAmount("-") == nil)
    }

    @Test func dates() throws {
        let parser = DateParser(dayFirst: true)
        #expect(parser.parse("02/10/2026", calendar: calendar).map(day) == DateComponents(year: 2026, month: 10, day: 2))
        #expect(parser.parse("2026-10-02", calendar: calendar).map(day) == DateComponents(year: 2026, month: 10, day: 2))
        #expect(parser.parse("02 Oct 2026", calendar: calendar).map(day) == DateComponents(year: 2026, month: 10, day: 2))
        #expect(parser.parse("2026年10月2日", calendar: calendar).map(day) == DateComponents(year: 2026, month: 10, day: 2))
        #expect(parser.parse("31/02/2026", calendar: calendar) == nil)
        #expect(parser.parse("WOOLWORTHS", calendar: calendar) == nil)
        // 只有日期的记在中午
        let noon = try #require(parser.parse("02/10/2026", calendar: calendar))
        #expect(calendar.component(.hour, from: noon) == 12)
        #expect(DateParser(samples: ["10/01/2026", "10/15/2026"]).dayFirst == false)
        #expect(DateParser(samples: ["01/10/2026", "15/10/2026"]).dayFirst == true)
    }

    @Test func unrecognizedFile() {
        #expect(throws: CSVImporter.ImportError.self) {
            try CSVImporter.parse(Data("hello,world\nfoo,bar\n".utf8), calendar: calendar)
        }
    }

    @Test func quotedFields() {
        let rows = CSVImporter.parseRows("a,\"b, with comma\",\"say \"\"hi\"\"\"\r\nc,\"multi\nline\",d\n")
        #expect(rows == [["a", "b, with comma", "say \"hi\""], ["c", "multi\nline", "d"]])
    }
}
