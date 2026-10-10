import Foundation

/// 发给 Worker 分析的一条消息（邮件、分享进来的聊天记录……）
struct InboxMessage: Codable, Sendable {
    var id: String
    var source: String
    var from: String
    var subject: String
    var receivedAt: Date
    var body: String
}

/// 调用自己部署的 Cloudflare Worker
struct DSAClient: Sendable {
    var baseURL: URL
    var token: String

    enum ClientError: LocalizedError {
        case notConfigured
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "还没有在设置里填写 Worker 地址和口令"
            case let .http(code, body): "Worker 返回 \(code)：\(body)"
            }
        }
    }

    static func fromSettings() throws -> DSAClient {
        guard let url = AppSettings.workerURL, let token = AppSettings.workerToken, !token.isEmpty else {
            throw ClientError.notConfigured
        }
        return DSAClient(baseURL: url, token: token)
    }

    // MARK: - /health

    func health() async throws {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
    }

    // MARK: - /analyze

    private struct AnalyzeRequest: Encodable {
        var messages: [InboxMessage]
        var now: Date
        var timezone: String
    }

    private struct AnalyzeResponse: Decodable {
        struct Task: Decodable {
            var sourceId: String
            var title: String
            var kind: String
            var due: Date?
            var importance: Int
            var reason: String
        }
        var tasks: [Task]
    }

    /// 让 Claude 从消息里找出需要处理的事。
    /// 纯信息类消息由 Worker 过滤掉，只有命中「特别关注」的才会以 info 返回
    func analyze(_ messages: [InboxMessage], source: TaskSource) async throws -> [TaskDraft] {
        guard !messages.isEmpty else { return [] }

        let decoded: AnalyzeResponse = try await post(
            "analyze",
            body: AnalyzeRequest(messages: messages, now: .now, timezone: TimeZone.current.identifier),
            timeout: 90
        )

        return decoded.tasks.compactMap { task in
            guard let kind = TaskKind(rawValue: task.kind) else { return nil }
            return TaskDraft(
                sourceID: task.sourceId,
                title: task.title,
                detail: task.reason,
                source: source,
                kind: kind,
                importance: Importance(rawValue: task.importance) ?? .important,
                due: task.due
            )
        }
    }

    // MARK: - /receipt、/categorize（记账）

    struct CategoryRef: Encodable, Sendable {
        var id: String
        var name: String
    }

    struct ReceiptResult: Decodable, Sendable {
        var isReceipt: Bool
        var merchant: String
        var total: Double?
        var currency: String
        var date: String?
        var categoryId: String
        var note: String
    }

    private struct ReceiptRequest: Encodable {
        var image: String
        var mediaType = "image/jpeg"
        var categories: [CategoryRef]
        var currencyHint: String
        var timezone: String
    }

    /// 让 Claude 读小票图片（JPEG）
    func receipt(jpeg: Data, categories: [CategoryRef], currencyHint: Currency) async throws -> ReceiptResult {
        try await post(
            "receipt",
            body: ReceiptRequest(
                image: jpeg.base64EncodedString(),
                categories: categories,
                currencyHint: currencyHint.rawValue,
                timezone: TimeZone.current.identifier
            ),
            timeout: 60
        )
    }

    struct CategorizeItem: Encodable, Sendable {
        var id: String
        var merchant: String
        var amount: Double?
    }

    struct CategorizeResult: Decodable, Sendable {
        var id: String
        var categoryId: String
        /// 整理后的商家名（"WOOLWORTHS 1234 SYDNEY AU" → "Woolworths"）
        var merchant: String
    }

    private struct CategorizeRequest: Encodable {
        var items: [CategorizeItem]
        var categories: [CategoryRef]
    }

    private struct CategorizeResponse: Decodable {
        var results: [CategorizeResult]
    }

    /// 商家名 → 分类（一次最多 200 条）
    func categorize(_ items: [CategorizeItem], categories: [CategoryRef]) async throws -> [CategorizeResult] {
        guard !items.isEmpty else { return [] }
        let response: CategorizeResponse = try await post(
            "categorize", body: CategorizeRequest(items: items, categories: categories), timeout: 90
        )
        return response.results
    }

    // MARK: - /charges（邮件自动记账）

    struct ChargeResult: Decodable, Sendable {
        var sourceId: String
        /// 同一封邮件里第几笔，形如 "gmail:<id>#0"，去重用
        var externalId: String
        /// expense / refund
        var kind: String
        var merchant: String
        var amount: Double
        var currency: String
        var date: String?
        var categoryId: String
        var note: String
        var recurring: Bool
    }

    private struct ChargesRequest: Encodable {
        var messages: [InboxMessage]
        var categories: [CategoryRef]
        var incomeCategories: [CategoryRef]
        var currencyHint: String
        var timezone: String
    }

    private struct ChargesResponse: Decodable {
        var charges: [ChargeResult]
    }

    /// 从付款收据邮件里提取已发生的扣款 / 退款
    func charges(_ messages: [InboxMessage], expense: [CategoryRef], income: [CategoryRef], currencyHint: Currency) async throws -> [ChargeResult] {
        guard !messages.isEmpty else { return [] }
        let response: ChargesResponse = try await post(
            "charges",
            body: ChargesRequest(
                messages: messages, categories: expense, incomeCategories: income,
                currencyHint: currencyHint.rawValue, timezone: TimeZone.current.identifier
            ),
            timeout: 90
        )
        return response.charges
    }

    // MARK: - /news

    struct NewsDates: Decodable, Sendable {
        /// 用户时区的今天
        var today: String
        /// 有简报的日期，新的在前
        var dates: [String]
        var monthCostUSD: Double
        /// 今天的简报已经提交 Batch API，正在排队生成（旧版 Worker 没有这个字段）
        var todayPending: Bool?
    }

    private struct BriefResponse: Decodable { var brief: NewsBrief }
    private struct ReportResponse: Decodable { var report: NewsReport }
    private struct GenerateRequest: Encodable { var force = false }
    private struct ReportRequest: Encodable { var date: String; var id: String; var generate: Bool }

    func newsDates() async throws -> NewsDates {
        try await get("news/dates", timeout: 30)
    }

    /// 这一天还没有简报时返回 nil
    func newsBrief(date: String) async throws -> NewsBrief? {
        do {
            let response: BriefResponse = try await get("news/brief", query: ["date": date], timeout: 30)
            return response.brief
        } catch ClientError.http(404, _) {
            return nil
        }
    }

    /// 立即生成今天的简报（抓新闻源 + Claude 写简报，大约 1–2 分钟）
    func generateNews() async throws -> NewsBrief {
        let response: BriefResponse = try await post("news/generate", body: GenerateRequest(), timeout: 300)
        return response.brief
    }

    /// 已经生成过的深度报道（别的设备生成的也算）；没有返回 nil，不会调用 Claude、不花钱
    func cachedNewsReport(date: String, id: String) async throws -> NewsReport? {
        do {
            let response: ReportResponse = try await post("news/report", body: ReportRequest(date: date, id: id, generate: false), timeout: 30)
            return response.report
        } catch ClientError.http(404, _) {
            return nil
        }
    }

    /// 生成深度报道：Worker 有缓存就直接返回，没有就现场生成（30–90 秒，按次计费）
    func generateNewsReport(date: String, id: String) async throws -> NewsReport {
        let response: ReportResponse = try await post("news/report", body: ReportRequest(date: date, id: id, generate: true), timeout: 300)
        return response.report
    }

    // MARK: - /config：个人资料、新闻设置、AI 服务（存在 Worker 的 KV 里）

    func config() async throws -> ConfigResponse {
        try await get("config", timeout: 30)
    }

    func saveConfig(_ config: UserConfig) async throws -> ConfigResponse {
        try await send("PUT", "config", body: config, timeout: 30)
    }

    // MARK: - 工具

    private func get<Response: Decodable>(_ path: String, query: [String: String] = [:], timeout: TimeInterval) async throws -> Response {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try Self.decoder.decode(Response.self, from: data)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, timeout: TimeInterval) async throws -> Response {
        try await send("POST", path, body: body, timeout: timeout)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body, timeout: TimeInterval) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = timeout
        request.httpBody = try Self.encoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        return try Self.decoder.decode(Response.self, from: data)
    }

    private static func check(_ response: URLResponse, _ data: Data) throws {
        struct ErrorBody: Decodable { var error: String }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            // Worker 的错误是 {"error": "..."}，只显示里面的说明
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error
            throw ClientError.http(http.statusCode, message ?? String(decoding: data.prefix(300), as: UTF8.self))
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Worker 返回的时间可能带或不带时区偏移、带或不带秒的小数部分
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(raw, strategy: .iso8601) { return date }
            if let date = try? Date(raw, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "无法解析时间 \(raw)"))
        }
        return d
    }()
}
