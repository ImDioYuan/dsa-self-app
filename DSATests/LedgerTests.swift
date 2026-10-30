import Foundation
import ImageIO
import SwiftData
import Testing
@testable import DSA

@Suite("汇率换算")
struct CurrencyTests {
    let table = RateTable(date: "2026-10-01", rates: ["CNY": 4.66, "USD": 0.69505, "JPY": 109.81])

    @Test func audIsIdentity() {
        #expect(table.perAUD(.AUD) == 1)
        #expect(table.rateToBase(.AUD) == 1)
    }

    @Test func roundTripThroughBase() throws {
        // ¥100 → AUD → ¥100
        let rate = try #require(table.rateToBase(.CNY))
        let aud = 100 * rate
        #expect(abs(aud - 21.4592) < 0.001)
        #expect(abs(table.fromBase(aud, to: .CNY) - 100) < 0.0001)
    }

    @Test func crossCurrency() throws {
        // $10 USD 显示成人民币 ≈ ¥67.05
        let aud = 10 * (try #require(table.rateToBase(.USD)))
        #expect(abs(table.fromBase(aud, to: .CNY) - 67.046) < 0.01)
    }

    @Test func unknownCurrencyHasNoRate() {
        #expect(table.rateToBase(.EUR) == nil)
    }
}

@Suite("记账统计")
struct LedgerStatsTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }()

    func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
    }

    var entries: [EntryValue] {
        [
            EntryValue(kind: .expense, baseAmount: 12.5, categoryID: "food", date: day(2026, 10, 1)),
            EntryValue(kind: .expense, baseAmount: 80, categoryID: "groceries", date: day(2026, 10, 1, hour: 18)),
            EntryValue(kind: .expense, baseAmount: 20, categoryID: "food", date: day(2026, 10, 3)),
            EntryValue(kind: .income, baseAmount: 500, categoryID: "salary", date: day(2026, 10, 2)),
            // 上个月和明年的，不应算进 10 月
            EntryValue(kind: .expense, baseAmount: 999, categoryID: "rent", date: day(2026, 9, 30, hour: 23)),
            EntryValue(kind: .expense, baseAmount: 1, categoryID: "food", date: day(2027, 1, 1)),
        ]
    }

    @Test func monthTotals() {
        let october = LedgerStats.monthInterval(containing: day(2026, 10, 15), calendar: calendar)
        let totals = LedgerStats.totals(LedgerStats.filter(entries, in: october))
        #expect(totals.expense == 112.5)
        #expect(totals.income == 500)
        #expect(totals.net == 387.5)
    }

    @Test func categoryBreakdownSortedDescending() {
        let october = LedgerStats.monthInterval(containing: day(2026, 10, 15), calendar: calendar)
        let items = LedgerStats.byCategory(LedgerStats.filter(entries, in: october), kind: .expense)
        #expect(items.map(\.categoryID) == ["groceries", "food"])
        #expect(items.map(\.total) == [80, 32.5])
    }

    @Test func dailyExpenseFillsEveryDay() {
        let october = LedgerStats.monthInterval(containing: day(2026, 10, 15), calendar: calendar)
        let daily = LedgerStats.dailyExpense(entries, month: october, calendar: calendar)
        #expect(daily.count == 31)
        #expect(daily[0].total == 92.5)   // 10/1：12.5 + 80
        #expect(daily[1].total == 0)      // 10/2 只有收入
        #expect(daily[2].total == 20)
    }

    @Test func monthlyCoversTwelveMonths() {
        let year = LedgerStats.yearInterval(containing: day(2026, 6, 1), calendar: calendar)
        let months = LedgerStats.monthly(entries, year: year, calendar: calendar)
        #expect(months.count == 12)
        #expect(months[8].totals.expense == 999)    // 9 月
        #expect(months[9].totals.expense == 112.5)  // 10 月
        #expect(months[9].totals.income == 500)
    }

    @Test(arguments: [
        (spent: 0.0, budget: 1000.0, level: BudgetLevel.normal),
        (spent: 799.0, budget: 1000.0, level: BudgetLevel.normal),
        (spent: 800.0, budget: 1000.0, level: BudgetLevel.warning),
        (spent: 1000.0, budget: 1000.0, level: BudgetLevel.over),
        (spent: 50.0, budget: 0.0, level: BudgetLevel.normal),
    ])
    func budgetLevels(spent: Double, budget: Double, level: BudgetLevel) {
        #expect(LedgerStats.budget(spent: spent, budget: budget).level == level)
    }

    @Test func dailyAllowanceIncludesToday() throws {
        let october = LedgerStats.monthInterval(containing: day(2026, 10, 15), calendar: calendar)
        // 10/22 中午，剩 10 天（22～31 号）
        let perDay = try #require(LedgerStats.dailyAllowance(remaining: 300, month: october, now: day(2026, 10, 22), calendar: calendar))
        #expect(perDay == 30)
        #expect(LedgerStats.dailyAllowance(remaining: -5, month: october, now: day(2026, 10, 22), calendar: calendar) == nil)
    }
}

@Suite("小票识别")
struct ReceiptScannerTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }()
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 19, minute: 41))! }

    @Test func parsesDateTime() throws {
        let date = try #require(ReceiptScanner.parseDate("2026-09-28T13:05", now: now, calendar: calendar))
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        #expect(c == DateComponents(year: 2026, month: 9, day: 28, hour: 13, minute: 5))
    }

    @Test func dateOnlyTodayUsesNow() {
        #expect(ReceiptScanner.parseDate("2026-10-02", now: now, calendar: calendar) == now)
    }

    @Test func dateOnlyPastUsesNoon() throws {
        let date = try #require(ReceiptScanner.parseDate("2026-09-30", now: now, calendar: calendar))
        #expect(calendar.component(.hour, from: date) == 12)
    }

    @Test func futureDateIgnored() {
        #expect(ReceiptScanner.parseDate("2027-01-01", now: now, calendar: calendar) == nil)
        #expect(ReceiptScanner.parseDate("garbage", now: now, calendar: calendar) == nil)
    }

    @Test func downscalesLargeImage() throws {
        // 生成一张 3000×2000 的 PNG，缩完长边应该是 1280，并且是 JPEG
        let width = 3000, height = 2000
        let ctx = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let png = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try #require(ctx.makeImage()), nil)
        #expect(CGImageDestinationFinalize(dest))

        let jpeg = try #require(ReceiptScanner.downscaledJPEG(png as Data))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 1280)
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }
}

@Suite("邮件自动记账")
struct EmailChargeTests {
    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Australia/Sydney")!
        return c
    }()

    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func dueOnlyAfterEightOncePerDay() {
        // 8 点前不跑
        #expect(!EmailChargeScanner.isDue(now: at(3, 7, 59), lastRun: nil, calendar: calendar))
        // 8 点后、从没跑过 → 跑
        #expect(EmailChargeScanner.isDue(now: at(3, 8, 1), lastRun: nil, calendar: calendar))
        // 昨天跑过 → 今天 8 点后再跑
        #expect(EmailChargeScanner.isDue(now: at(3, 9), lastRun: at(2, 21), calendar: calendar))
        // 今天 8 点后已经跑过 → 不跑
        #expect(!EmailChargeScanner.isDue(now: at(3, 20), lastRun: at(3, 8, 5), calendar: calendar))
        // 今天早上 7 点手动跑过，8 点后还要再跑一次
        #expect(EmailChargeScanner.isDue(now: at(3, 8, 30), lastRun: at(3, 7), calendar: calendar))
    }

    func candidate(_ merchant: String, _ amount: String, day: Int, kind: LedgerKind = .expense, currency: Currency = .AUD) -> EmailChargeScanner.Candidate {
        .init(kind: kind, amount: Decimal(string: amount)!, currency: currency, merchant: merchant,
              date: at(day, 12), categoryID: "food", note: "", externalID: "email:x#0")
    }

    func existing(_ merchant: String, _ amount: String, day: Int, kind: LedgerKind = .expense, currency: Currency = .AUD) -> EmailChargeScanner.ExistingEntry {
        .init(kind: kind, amount: Decimal(string: amount)!, currency: currency, merchant: merchant, date: at(day, 19))
    }

    @Test func detectsApplePayDuplicate() {
        // Apple Pay 记的是「Uber Eats」（Claude 整理过），邮件里是「Uber Eats」收据，第二天才到
        #expect(EmailChargeScanner.isDuplicate(candidate("Uber Eats", "23.40", day: 3), of: [existing("Uber Eats", "23.40", day: 2)]))
        // 商家名写法不同但品牌一样
        #expect(EmailChargeScanner.isDuplicate(candidate("Woolworths Online", "56.10", day: 3), of: [existing("WOOLWORTHS 1234 SYDNEY AU", "56.10", day: 3)]))
    }

    @Test func notDuplicateWhenDifferent() {
        let e = [existing("Netflix", "18.99", day: 3)]
        #expect(!EmailChargeScanner.isDuplicate(candidate("Netflix", "22.99", day: 3), of: e))            // 金额不同
        #expect(!EmailChargeScanner.isDuplicate(candidate("Spotify", "18.99", day: 3), of: e))            // 商家不同
        #expect(!EmailChargeScanner.isDuplicate(candidate("Netflix", "18.99", day: 9), of: e))            // 隔了好几天（下个周期）
        #expect(!EmailChargeScanner.isDuplicate(candidate("Netflix", "18.99", day: 3, kind: .income), of: e))  // 退款不等于扣款
        #expect(!EmailChargeScanner.isDuplicate(candidate("Netflix", "18.99", day: 3, currency: .USD), of: e)) // 币种不同
    }

    @Test func detectsDuplicateAcrossCurrencies() {
        // 邮件收据记的是 USD 15.99（当时折合 A$24.50），过两天银行账单里扣的是 A$25.20（含汇率差价和海外手续费）
        var receipt = existing("Netflix", "15.99", day: 3, currency: .USD)
        receipt.baseAmount = 24.50
        var bank = candidate("NETFLIX.COM SYDNEY", "25.20", day: 5)
        bank.baseAmount = 25.20
        #expect(EmailChargeScanner.isDuplicate(bank, of: [receipt]))

        // 折成澳元差太多、隔太久、或者拿不到汇率的都不算
        var other = bank
        other.amount = 32
        other.baseAmount = 32
        #expect(!EmailChargeScanner.isDuplicate(other, of: [receipt]))
        other = candidate("NETFLIX.COM SYDNEY", "25.20", day: 8)
        other.baseAmount = 25.20
        #expect(!EmailChargeScanner.isDuplicate(other, of: [receipt]))
        other.baseAmount = nil
        #expect(!EmailChargeScanner.isDuplicate(other, of: [receipt]))
    }

    @Test func convertsChargeResult() throws {
        let raw = DSAClient.ChargeResult(
            sourceId: "gmail:abc", externalId: "gmail:abc#0", kind: "expense", merchant: "Netflix",
            amount: 18.989999, currency: "aud", date: "2026-10-01T06:30", categoryId: "entertainment",
            note: "Netflix 月度订阅", recurring: true
        )
        let c = try #require(EmailChargeScanner.candidate(from: raw, receivedAt: nil, incomeSlugs: ["refund"]))
        #expect(c.amount == Decimal(string: "18.99"))
        #expect(c.currency == .AUD)
        #expect(c.kind == .expense)
        #expect(c.externalID == "email:gmail:abc#0")

        // 退款：分类不在收入分类里时归到「退款」
        var refund = raw
        refund.kind = "refund"
        refund.merchant = "ZZRefundShop"
        let r = try #require(EmailChargeScanner.candidate(from: refund, receivedAt: nil, incomeSlugs: ["refund", "salary"]))
        #expect(r.kind == .income)
        #expect(r.categoryID == "refund")

        // 不支持的币种跳过
        var thb = raw
        thb.currency = "THB"
        #expect(EmailChargeScanner.candidate(from: thb, receivedAt: nil, incomeSlugs: []) == nil)
    }

    @Test func queryLooksBackRequestedDays() {
        let q = EmailChargeScanner.query(days: 3)
        #expect(q.hasPrefix("newer_than:3d ("))
        #expect(q.contains("receipt") && q.contains("扣费") && q.contains("-in:spam"))
    }
}

@Suite("主题色")
struct ThemeTests {
    @Test(arguments: ThemeColor.presets.map(\.color))
    func hsbRoundTrip(color: ThemeColor) {
        let (h, s, b) = color.hsb
        let back = ThemeColor.hsb(h, s, b)
        #expect(abs(back.red - color.red) < 0.0001)
        #expect(abs(back.green - color.green) < 0.0001)
        #expect(abs(back.blue - color.blue) < 0.0001)
    }

    @Test func storageRoundTrip() throws {
        let color = ThemeColor(red: 0.2, green: 0.55, blue: 0.95)
        #expect(ThemeColor(storage: color.storage) == color)
        #expect(ThemeColor(storage: "garbage") == nil)
    }

    @Test func pickedColorKeepsP3Components() throws {
        let original = ThemeColor(red: 0.98, green: 0.45, blue: 0.65)
        let picked = try #require(ThemeColor(original.color))
        #expect(abs(picked.red - original.red) < 0.01)
        #expect(abs(picked.green - original.green) < 0.01)
        #expect(abs(picked.blue - original.blue) < 0.01)
    }

    @Test func paletteSizes() {
        let palette = ThemePalette(base: .default)
        #expect(palette.backgroundColors(dark: false).count == 9)
        #expect(palette.backgroundColors(dark: true).count == 9)
        #expect(palette.widgetColors().count == 3)
        #expect(palette.widgetColors(dark: true).count == 3)
    }

    @Test func appearanceResolution() {
        #expect(AppearanceMode.system.isDark(system: .dark))
        #expect(!AppearanceMode.system.isDark(system: .light))
        #expect(AppearanceMode.dark.isDark(system: .light))
        #expect(!AppearanceMode.light.isDark(system: .dark))
        #expect(AppearanceMode.system.colorScheme == nil)
    }
}

@Suite("小组件快照")
struct SnapshotTests {
    let calendar = Calendar(identifier: .gregorian)

    func snapshot(day: Date) -> LedgerSnapshot {
        LedgerSnapshot(day: day, todayExpense: 42, monthExpense: 900, monthBudget: 1000,
                       currencyCode: "CNY", fractionDigits: 2, updatedAt: day)
    }

    @Test func todayResetsAfterMidnight() {
        let oct2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9))!
        let s = snapshot(day: oct2)
        #expect(s.todayExpense(now: oct2.addingTimeInterval(3600), calendar: calendar) == 42)
        #expect(s.todayExpense(now: oct2.addingTimeInterval(24 * 3600), calendar: calendar) == 0)
        #expect(s.monthExpense(now: oct2.addingTimeInterval(24 * 3600), calendar: calendar) == 900)
    }

    @Test func monthResetsNextMonth() {
        let oct31 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 22))!
        let nov1 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 8))!
        #expect(snapshot(day: oct31).monthExpense(now: nov1, calendar: calendar) == 0)
    }

    @Test func formatsInSnapshotCurrency() {
        #expect(snapshot(day: .now).format(42).contains("42.00"))
    }
}

@MainActor
@Suite("快捷方式", .serialized)
struct IntentTests {
    @Test func applePayTransactionUsesMemoryAndDedupes() async throws {
        let merchant = "ZZTESTSHOP 0563 SYDNEY AU"
        MerchantMemory.remember(merchant: "Zztestshop", categoryID: "groceries")
        defer { cleanUp(merchant: merchant) }

        let intent = LogTransactionIntent()
        intent.amount = 12.5
        intent.merchant = merchant
        intent.currencyCode = "aud"
        _ = try await intent.perform()
        // 自动化重复触发：同一分钟同商家同金额只记一次
        _ = try await intent.perform()

        let entries = try fetch(merchant: merchant)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.categoryID == "groceries")
        #expect(entry.amount == Decimal(string: "12.50"))
        #expect(entry.currencyValue == .AUD)
        #expect(entry.source == .applePay)
    }

    @Test func quickAddRoutesToLedger() async throws {
        AppRouter.shared.tab = .tasks
        _ = try await QuickAddIntent().perform()
        #expect(AppRouter.shared.tab == .ledger)
        #expect(AppRouter.shared.pendingDraft != nil)
        AppRouter.shared.pendingDraft = nil
    }

    private func fetch(merchant: String) throws -> [LedgerEntry] {
        let target = merchant
        return try LedgerStore.context.fetch(FetchDescriptor<LedgerEntry>(predicate: #Predicate { $0.merchant == target }))
    }

    private func cleanUp(merchant: String) {
        for entry in (try? fetch(merchant: merchant)) ?? [] { LedgerStore.context.delete(entry) }
        try? LedgerStore.context.save()
        var map = UserDefaults.standard.dictionary(forKey: LedgerSettingsKey.merchantMap) as? [String: String] ?? [:]
        map["zztestshop"] = nil
        UserDefaults.standard.set(map, forKey: LedgerSettingsKey.merchantMap)
    }
}

@Suite("商家归一化")
struct MerchantMemoryTests {
    @Test(arguments: [
        ("WOOLWORTHS 1234 SYDNEY AU", "woolworths"),
        ("Woolworths", "woolworths"),
        ("Woolworths Metro", "woolworths"),
        ("UBER *EATS", "uber eats"),
        ("Uber Trip", "uber trip"),
        ("SQ *CAFE ABC", "sq cafe"),
        ("", ""),
    ])
    func normalize(input: String, expected: String) {
        #expect(MerchantMemory.normalize(input) == expected)
    }
}

@Suite("任务去重")
@MainActor
struct TaskDedupeTests {
    @Test func sameTitleAndMinuteIsSameTask() {
        let due = Date(timeIntervalSince1970: 1_790_000_000)
        #expect(TaskItem.dedupeKey(title: "MATH2821 Lecture", due: due) == TaskItem.dedupeKey(title: "math2821  lecture.", due: due.addingTimeInterval(20)))
        #expect(TaskItem.dedupeKey(title: "MATH2821 Lecture", due: due) != TaskItem.dedupeKey(title: "MATH2821 Lecture", due: due.addingTimeInterval(3600)))
        #expect(TaskItem.dedupeKey(title: "回复 Alex", due: nil) == TaskItem.dedupeKey(title: "回复Alex", due: nil))
    }

    @Test func mergeRemovesCopiesWithSameSourceID() throws {
        let container = try ModelContainer(for: TaskItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let draft = TaskDraft(sourceID: "moodle:1", title: "Quiz 1", source: .ical, kind: .deadline, importance: .trivial)
        let done = TaskItem(draft: draft)
        done.isDone = true
        context.insert(TaskItem(draft: draft))
        context.insert(done)
        context.insert(TaskItem(draft: draft))

        TaskSyncService.merge([draft], from: .ical, into: context)

        let left = try context.fetch(FetchDescriptor<TaskItem>())
        #expect(left.count == 1)
        #expect(left.first?.isDone == true)
    }

    @Test func turningSourceOffRemovesItsTasks() throws {
        let container = try ModelContainer(for: TaskItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let meeting = TaskItem(draft: TaskDraft(sourceID: "calendar:1", title: "Tutorial", source: .calendar, kind: .meeting, importance: .normal))
        let doneMeeting = TaskItem(draft: TaskDraft(sourceID: "calendar:2", title: "Lecture", source: .calendar, kind: .meeting, importance: .trivial))
        doneMeeting.isDone = true
        context.insert(meeting)
        context.insert(doneMeeting)
        context.insert(TaskItem(draft: TaskDraft(sourceID: "reminders:1", title: "交房租", source: .reminders, kind: .deadline, importance: .critical)))
        context.insert(TaskItem(draft: TaskDraft(sourceID: "manual:1", title: "COMP3311 Assignment 2", source: .manual, kind: .deadline, importance: .critical)))

        TaskSyncService.removeTasks(from: [.calendar], in: context)

        let left = try context.fetch(FetchDescriptor<TaskItem>()).map(\.sourceID).sorted()
        #expect(left == ["manual:1", "reminders:1"])
    }

    @Test func deletedTasksStayDeleted() throws {
        let deleted = DeletedTasks(source: .calendar)
        let reminders = DeletedTasks(source: .reminders)
        let saved = [deleted.key, reminders.key].map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (key, value) in saved { UserDefaults.standard.set(value, forKey: key) } }
        deleted.removeAll()
        reminders.removeAll()

        let container = try ModelContainer(for: TaskItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let lecture = TaskDraft(sourceID: "calendar:1", title: "Lecture", source: .calendar, kind: .meeting, importance: .normal)
        let tutorial = TaskDraft(sourceID: "calendar:2", title: "Tutorial", source: .calendar, kind: .meeting, importance: .normal)
        TaskSyncService.merge([lecture, tutorial], from: .calendar, into: context)
        let item = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.sourceID == "calendar:1" })
        TaskSyncService.delete([item], in: context)

        // 日历里还有这一项：同步后也不再出现
        TaskSyncService.merge([lecture, tutorial], from: .calendar, into: context)
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).map(\.sourceID) == ["calendar:2"])
        #expect(deleted.entries.count == 1)

        // 日历不再返回它（过期了或者删了）：忘掉
        TaskSyncService.merge([tutorial], from: .calendar, into: context)
        #expect(deleted.entries.isEmpty)

        // 重复的提醒事项每次都是同一个 sourceID：删掉今天这次，下一次照常出现
        let today = Date(timeIntervalSince1970: 1_791_525_600)
        var pills = TaskDraft(sourceID: "reminders:9", title: "吃药", source: .reminders, kind: .deadline, importance: .important, due: today)
        TaskSyncService.merge([pills], from: .reminders, into: context)
        let first = try #require(try context.fetch(FetchDescriptor<TaskItem>()).first { $0.sourceID == "reminders:9" })
        TaskSyncService.delete([first], in: context)
        TaskSyncService.merge([pills], from: .reminders, into: context)
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).allSatisfy { $0.sourceID != "reminders:9" })
        pills.due = today.addingTimeInterval(24 * 3600)
        TaskSyncService.merge([pills], from: .reminders, into: context)
        #expect(try context.fetch(FetchDescriptor<TaskItem>()).contains { $0.sourceID == "reminders:9" })

        // 关掉再打开数据源就重新开始
        TaskSyncService.delete(try context.fetch(FetchDescriptor<TaskItem>()).filter { $0.sourceID == "reminders:9" }, in: context)
        #expect(!reminders.entries.isEmpty)
        TaskSyncService.removeTasks(from: [.reminders], in: context)
        #expect(reminders.entries.isEmpty)
    }

    @Test func dateOnlyDueIsLastMinuteEvenOnDSTDays() throws {
        var sydney = Calendar(identifier: .gregorian)
        sydney.timeZone = try #require(TimeZone(identifier: "Australia/Sydney"))
        // 2026-10-04 夏令时开始（这天只有 23 小时），2027-04-04 结束（25 小时）
        for (year, month, day) in [(2026, 10, 4), (2027, 4, 4), (2026, 10, 30)] {
            let noon = try #require(sydney.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
            let due = noon.lastMinuteOfDay(in: sydney)
            #expect(sydney.dateComponents([.year, .month, .day, .hour, .minute], from: due)
                == DateComponents(year: year, month: month, day: day, hour: 23, minute: 59))
        }
    }

    // MARK: Moodle 和邮件里的同一个作业

    /// 周五 17:00（Moodle 上的准确时间）
    private let friday5pm = Date(timeIntervalSince1970: 1_791_525_600)

    private func task(_ title: String, _ detail: String = "", from source: TaskSource, kind: TaskKind = .deadline,
                      hours: Double = 0, done: Bool = false) -> TaskFingerprint {
        TaskFingerprint(title: title, detail: detail, source: source, kind: kind,
                        due: friday5pm.addingTimeInterval(hours * 3600), isDone: done)
    }

    private var moodle: TaskFingerprint { task("Assignment 2 is due", "COMP3311-5259_00123", from: .ical) }

    @Test(arguments: [
        ("提交 COMP3311 作业2", 6.98),               // 邮件只写了周五 → 23:59
        ("提交 COMP3311 Assignment 2", 0),
        ("COMP3311 第二次作业截止", 0),
        ("提交数据库作业二", 0),                      // 没写课程，但类型、编号、时间都对得上
        ("Submit COMP3311 Ass2 by 17:00 10月9日", -1),
    ])
    func emailCopyOfMoodleDeadlineIsSameTask(title: String, hours: Double) {
        #expect(task(title, from: .outlook, hours: hours).isSameTask(as: moodle))
    }

    @Test(arguments: [
        ("提交 COMP3311 作业3", 0.0),                 // 编号不同
        ("COMP3311 Quiz 2", 0),                       // 类型不同
        ("提交 COMP2521 作业2", 0),                   // 课程不同
        ("提交 COMP3311 作业2", 30),                  // 差了一天多
        ("完成 COMP3311 课前阅读", 3),               // 只有课程一样
    ])
    func differentTasksAreKept(title: String, hours: Double) {
        #expect(!task(title, from: .outlook, hours: hours).isSameTask(as: moodle))
    }

    @Test func sameSnapshotSourceAndRepliesAreNotMerged() {
        #expect(!task("Assignment 2 cut-off", "COMP3311", from: .ical, hours: 2).isSameTask(as: moodle))
        #expect(!task("回复老师关于 COMP3311 作业2", from: .outlook, kind: .reply).isSameTask(as: moodle))
        // 两封邮件说的是同一个作业
        #expect(task("提交 COMP3311 作业2", from: .outlook).isSameTask(as: task("COMP3311 Assignment 2 截止", from: .gmail)))
    }

    @Test func groupShowsMoodleAndFollowsDoneCopy() {
        let email = task("提交 COMP3311 作业2", from: .outlook, hours: 6.98)
        let other = task("提交 COMP3311 作业3", from: .outlook)
        #expect(TaskDuplicates.groups([email, moodle, other]) == [[1, 0], [2]])

        // 邮件那条已经勾掉了：整组算完成，显示完成的那条
        var doneEmail = email
        doneEmail.isDone = true
        #expect(TaskDuplicates.groups([moodle, doneEmail]) == [[1, 0]])

        // 没有时间、标题一样的：一条完成一条没完成是先后两件事
        let reply = TaskFingerprint(title: "回复 Alex", detail: "", source: .gmail, kind: .reply, due: nil, isDone: false)
        var oldReply = reply
        oldReply.isDone = true
        #expect(TaskDuplicates.groups([reply, oldReply, reply]) == [[0, 2], [1]])
    }

    // MARK: 两门课的同名作业

    @Test func sameTitleInTwoCoursesIsNotMerged() {
        // 同一个 Moodle 订阅里两门课都有「Quiz 1 closes」，截止时间也一样
        let math = task("Quiz 1 closes", "MATH2831-5259_00456", from: .ical)
        let comp = task("Quiz 1 closes", "COMP3311-5259_00123", from: .ical)
        #expect(!math.isSameTask(as: comp))
        #expect(TaskDuplicates.groups([math, comp]) == [[0], [1]])
        // 订阅在两个日历里的同一条照样合并
        #expect(TaskDuplicates.groups([math, task("Quiz 1 closes", from: .calendar)]) == [[0, 1]])
    }

    @Test func copyWithoutCourseDoesNotBridgeTwoCourses() {
        let comp = task("Assignment 2 is due", "COMP3311-5259_00123", from: .ical)
        let math = task("Assignment 2 is due", "MATH2831-5259_00456", from: .ical, hours: 5)
        // 苹果日历里订阅的同一条，没有课程
        let mathCopy = task("Assignment 2 is due", from: .calendar, hours: 5)
        #expect(TaskDuplicates.groups([comp, math, mathCopy]) == [[0], [1, 2]])

        // 没写课程的邮件同时像两门课的作业：说不清是哪门课的，单独显示
        let email = task("提交作业二", from: .gmail, hours: 6.98)
        #expect(TaskDuplicates.groups([comp, math, mathCopy, email]) == [[0], [1, 2], [3]])
        // 只像一门课的照样合并
        #expect(TaskDuplicates.groups([comp, email]) == [[0, 1]])

        // 一封邮件提醒两门课的作业 2，AI 写的理由里两门课都有：按标题里的课程分开
        let reason = "邮件提醒 COMP3311 和 MATH2831 的作业 2 都在周五截止"
        let compEmail = task("提交 COMP3311 Assignment 2", reason, from: .gmail, hours: 6.98)
        let mathEmail = task("提交 MATH2831 Assignment 2", reason, from: .gmail, hours: 6.98)
        #expect(TaskDuplicates.groups([comp, math, compEmail, mathEmail]) == [[0, 2], [1, 3]])
        // 标题里同时写了两门课的一条也不能把两门课连起来
        let joint = task("COMP3311 / MATH2831 Assignment 2", from: .gmail, hours: 6.98)
        #expect(TaskDuplicates.groups([comp, math, joint]).count == 2)
    }
}
