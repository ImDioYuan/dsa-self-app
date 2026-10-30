import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// 新闻板块的数据：当前显示的简报、往期日期、深度报道。
/// 简报和报道生成后不会再变，下载过的都存在本地，离线也能看、再打开不用等。
@MainActor
@Observable
final class NewsStore {
    static let shared = NewsStore()

    /// 当前显示的简报
    private(set) var brief: NewsBrief?
    /// 有简报的日期，新的在前
    private(set) var dates: [String] = []
    /// 用户时区的今天（Worker 按设置里的时区算）
    private(set) var today: String?
    private(set) var monthCostUSD: Double?
    /// 今天的简报正在 Batch API 排队（半价，一般几分钟内送到）
    private(set) var todayPending = false
    private(set) var isLoading = false
    private(set) var isGenerating = false
    private(set) var error: String?

    private(set) var reports: [String: NewsReport] = [:]
    private(set) var reportErrors: [String: String] = [:]
    /// 正在生成的报道
    private(set) var loadingReports: Set<String> = []
    /// 正在问 Worker 有没有已经生成好的报道（不花钱）
    private(set) var checkingReports: Set<String> = []

    private var refreshTask: Task<Void, Never>?
    private var lastRefresh: Date?

    private init() {
        brief = NewsCache.latestBrief()
    }

    /// 今天的简报还没有（正在显示以前的或者什么都没有）
    var todayMissing: Bool {
        guard let today else { return false }
        return brief?.date != today && !dates.contains(today)
    }

    // MARK: - 简报

    /// 打开新闻页、回到前台时调用：5 分钟内刷新过就跳过。正在看往期的某一天就留在那一天
    func refreshIfStale() {
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 5 * 60 { return }
        Task { await refresh(keepingPastBrief: true) }
    }

    /// 拉取日期列表并显示最新的简报（keepingPastBrief：正在看往期时只更新日期列表，不跳回最新一期）。
    /// 放在独立的 Task 里，切换页面不会把它取消掉；正在刷新时再调用就等这一次结束
    func refresh(keepingPastBrief: Bool = false) async {
        if let refreshTask { return await refreshTask.value }
        let task = Task {
            let pastDate = keepingPastBrief && !dates.isEmpty && brief?.date != dates.first ? brief?.date : nil
            await load(date: pastDate)
            refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    /// 切到往期的某一天
    func select(date: String) {
        Task { await load(date: date) }
    }

    private func load(date: String?) async {
        guard let client = try? DSAClient.fromSettings() else {
            error = DSAClient.ClientError.notConfigured.localizedDescription
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let info = try await client.newsDates()
            today = info.today
            dates = info.dates
            monthCostUSD = info.monthCostUSD
            todayPending = info.todayPending ?? false
            lastRefresh = .now
            error = nil

            guard let target = date ?? info.dates.first else { return }
            if let cached = NewsCache.brief(target) {
                brief = cached
            } else if let fetched = try await client.newsBrief(date: target) {
                NewsCache.save(fetched)
                brief = fetched
            }
        } catch let error where error.isCancellation {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 立即生成今天的简报
    func generateToday() async {
        guard !isGenerating else { return }
        guard let client = try? DSAClient.fromSettings() else {
            error = DSAClient.ClientError.notConfigured.localizedDescription
            return
        }
        isGenerating = true
        defer { isGenerating = false }
        error = nil
        // 切到别的 app、锁屏时多要一点后台时间，请求不会马上断
        let background = BackgroundTime(name: "生成今天的简报")
        defer { background.end() }
        do {
            let fresh = try await client.generateNews()
            NewsCache.save(fresh)
            brief = fresh
            if !dates.contains(fresh.date) { dates.insert(fresh.date, at: 0) }
            todayPending = false
            if let info = try? await client.newsDates() { monthCostUSD = info.monthCostUSD }
        } catch DSAClient.ClientError.http(409, _) {
            error = "简报正在生成，过一两分钟再下拉刷新"
        } catch let error where Self.connectionDropped(error) {
            // 连接断了，Worker 多半还在生成：等它存好再取（不花钱）
            let ready = await Self.poll { () async -> Bool? in
                guard let info = try? await client.newsDates() else { return nil }
                return info.dates.contains(info.today) ? true : nil
            }
            if ready == true {
                await load(date: nil)
            } else {
                self.error = "连接断了，简报没有生成完，过几分钟下拉刷新看看"
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 请求发出去以后连接断了（切出 App、锁屏、网络切换）或者等太久。Worker 那边多半还在生成，不急着报错。
    /// 没网（notConnectedToInternet）时请求根本没发出去，直接报错
    private static func connectionDropped(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return code == .networkConnectionLost || code == .timedOut
    }

    /// 每 10 秒问一次 Worker 存好了没有，最多等 3 分钟
    private static func poll<T>(_ check: () async -> T?) async -> T? {
        for _ in 0..<18 {
            try? await Task.sleep(for: .seconds(10))
            if let result = await check() { return result }
        }
        return nil
    }

    // MARK: - 阅读情况（Worker 用它学习你的兴趣）

    /// 👍 1 / 👎 -1，key 和深度报道一样是 日期#id。存在本机，图标高亮用；Worker 也有一份用来打分
    private(set) var votes: [String: Int] = UserDefaults.standard.dictionary(forKey: "news.votes") as? [String: Int] ?? [:]

    /// 点同一个再点一次就取消
    func vote(date: String, id: String, _ value: Int) {
        let key = Self.reportKey(date: date, id: id)
        let new = votes[key] == value ? 0 : value
        votes[key] = new == 0 ? nil : new
        // 只留最近的，免得越存越多
        if votes.count > 300 {
            for old in votes.keys.sorted().prefix(votes.count - 300) { votes[old] = nil }
        }
        UserDefaults.standard.set(votes, forKey: "news.votes")
        sendFeedback(.init(date: date, id: id, event: "vote", vote: new))
    }

    func recordOpen(date: String, id: String) {
        sendFeedback(.init(date: date, id: id, event: "open"))
    }

    func recordRead(date: String, id: String, seconds: TimeInterval) {
        guard seconds >= 1 else { return }
        sendFeedback(.init(date: date, id: id, event: "read", seconds: seconds.rounded()))
    }

    func recordLink(date: String, id: String) {
        sendFeedback(.init(date: date, id: id, event: "link"))
    }

    /// 发不出去（没网、Worker 没配好）就算了，不重试
    private func sendFeedback(_ event: DSAClient.FeedbackEvent) {
        guard let client = try? DSAClient.fromSettings() else { return }
        Task { try? await client.newsFeedback(event) }
    }

    // MARK: - 深度报道

    static func reportKey(date: String, id: String) -> String { "\(date)#\(id)" }

    func report(date: String, id: String) -> NewsReport? {
        reports[Self.reportKey(date: date, id: id)]
    }

    /// 打开详情页时调用：只取已经生成好的（本地缓存 → Worker 缓存），没有就等用户点「生成深度报道」。不花钱
    func loadReport(date: String, id: String) {
        let key = Self.reportKey(date: date, id: id)
        guard reports[key] == nil, !loadingReports.contains(key), !checkingReports.contains(key) else { return }
        if let cached = NewsCache.report(date: date, id: id) {
            reports[key] = cached
            return
        }
        guard let client = try? DSAClient.fromSettings() else { return }
        checkingReports.insert(key)
        Task {
            defer { checkingReports.remove(key) }
            // 查不到或者网络出错都当作还没生成，按钮照常显示
            if let report = try? await client.cachedNewsReport(date: date, id: id) {
                NewsCache.save(report, date: date, id: id)
                reports[key] = report
            }
        }
    }

    /// 点「生成深度报道」：Claude 读原文、查背景后写报道（30–90 秒，按次计费）。离开详情页也会继续生成完；
    /// 切出 App 时连接可能会断，Worker 会再跑一会儿把报道存好，这里等它存好再取
    func generateReport(date: String, id: String) {
        let key = Self.reportKey(date: date, id: id)
        guard reports[key] == nil, !loadingReports.contains(key) else { return }
        guard let client = try? DSAClient.fromSettings() else {
            reportErrors[key] = DSAClient.ClientError.notConfigured.localizedDescription
            return
        }
        loadingReports.insert(key)
        reportErrors[key] = nil
        Task {
            defer { loadingReports.remove(key) }
            // 点开原文、切到别的 app、锁屏时多要一点后台时间，请求不会马上断
            let background = BackgroundTime(name: "生成深度报道")
            defer { background.end() }
            let report: NewsReport
            do {
                report = try await client.generateNewsReport(date: date, id: id)
            } catch DSAClient.ClientError.http(409, _) {
                reportErrors[key] = "这篇报道正在生成，稍后再打开看看"
                return
            } catch let error where Self.connectionDropped(error) {
                // 连接断了，Worker 多半还在写：等它存好再取（不花钱）
                guard let saved = await Self.poll({ try? await client.cachedNewsReport(date: date, id: id) }) else {
                    reportErrors[key] = "连接断了，报道没有生成完，几分钟后可以重试"
                    return
                }
                report = saved
            } catch {
                reportErrors[key] = error.localizedDescription
                return
            }
            NewsCache.save(report, date: date, id: id)
            reports[key] = report
            // 底部的「本月新闻花费」跟着更新
            if let info = try? await client.newsDates() { monthCostUSD = info.monthCostUSD }
        }
    }
}

/// 切到别的 app、锁屏时向系统多要一点后台时间（一般 30 秒左右），正在等的请求不会马上断。Mac 上不需要
@MainActor
private final class BackgroundTime {
    #if os(iOS)
    private var id = UIBackgroundTaskIdentifier.invalid
    #endif

    init(name: String) {
        #if os(iOS)
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
        #endif
    }

    func end() {
        #if os(iOS)
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
        #endif
    }
}

// MARK: - 本地缓存

/// Application Support/News 下的 JSON 文件：brief-2026-10-03.json、report-2026-10-03-5.json
enum NewsCache {
    /// 本地保留 60 天
    static let keepDays = 60

    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "News", directoryHint: .isDirectory)
    }

    static func brief(_ date: String) -> NewsBrief? {
        read(NewsBrief.self, "brief-\(date).json")
    }

    static func latestBrief() -> NewsBrief? {
        guard let newest = fileNames().filter({ $0.hasPrefix("brief-") && $0.hasSuffix(".json") }).max() else { return nil }
        return read(NewsBrief.self, newest)
    }

    static func save(_ brief: NewsBrief) {
        write(brief, "brief-\(brief.date).json")
        prune()
    }

    static func report(date: String, id: String) -> NewsReport? {
        read(NewsReport.self, "report-\(date)-\(id).json")
    }

    static func save(_ report: NewsReport, date: String, id: String) {
        write(report, "report-\(date)-\(id).json")
    }

    private static func fileNames() -> [String] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.map(\.lastPathComponent)
    }

    private static func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? DSAClient.decoder.decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? DSAClient.encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: name), options: .atomic)
    }

    /// 删掉 60 天以前的简报和报道（文件名里的日期按字符串比较就行）
    private static func prune() {
        let cutoff = Date.now.addingTimeInterval(-Double(keepDays) * 86_400)
        let cutoffName = cutoff.formatted(.iso8601.year().month().day())
        for name in fileNames() {
            let parts = name.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, String(parts[1].prefix(10)) < cutoffName else { continue }
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}
