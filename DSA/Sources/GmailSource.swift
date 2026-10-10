import Foundation

/// Gmail：拉取最近几天的新邮件 → 交给 Worker 里的 AI 判断 → 只留下需要处理的事。
/// 学校 / 公司邮箱（例如 Outlook）转发到 Gmail 后，可以用过滤器归到一个标签并跳过收件箱，
/// 在设置里填这个标签名，这里也一并读取，来源标成 Outlook。
struct GmailSource: TaskSourceProvider {
    let source = TaskSource.gmail

    /// 每条搜索条件，以及搜到的邮件算哪个来源
    var queries: [(query: String, source: TaskSource)] = GmailSource.defaultQueries()
    var maxMessages = 30

    static func defaultQueries(
        forwardedLabel: String? = AppSettings.gmailForwardedLabel,
        extraQuery: String? = AppSettings.gmailExtraQuery
    ) -> [(query: String, source: TaskSource)] {
        // 最近 3 天收件箱里的邮件，跳过推广、社交、论坛分类
        var queries: [(query: String, source: TaskSource)] = [
            ("in:inbox newer_than:3d -category:promotions -category:social -category:forums", .gmail),
        ]
        // 特别关注：不管被 Gmail 分到哪个分类都要搜出来（配合 Worker 里的特别关注规则）
        if let extraQuery { queries.append(("newer_than:3d (\(extraQuery))", .gmail)) }
        // 转发过来的邮件。Gmail 搜索里标签名的空格要写成 -
        if let forwardedLabel {
            queries.append(("label:\(forwardedLabel.replacingOccurrences(of: " ", with: "-")) newer_than:3d", .outlook))
        }
        return queries
    }

    func fetch() async throws -> [TaskDraft] {
        guard GoogleAuth.isSignedIn else { return [] }
        let client = try DSAClient.fromSettings()
        let api = GmailAPI(accessToken: try await GoogleAuth.validAccessToken())

        // 邮件 id → 来源；同一封邮件被多条搜索命中时，以后面的（转发标签）为准
        var sourceByID: [String: TaskSource] = [:]
        var ids: [String] = []
        for (query, source) in queries {
            for id in try await api.listMessageIDs(query: query, max: maxMessages) {
                if sourceByID[id] == nil { ids.append(id) }
                sourceByID[id] = source
            }
        }
        // 分析过的邮件不再重复发给 Claude；Worker 一次最多收 50 封，剩下的下次同步再分析
        let newIDs = Array(ids.filter { !AnalyzedLog.gmail.contains($0) }.prefix(50))
        guard !newIDs.isEmpty else { return [] }

        let messages = try await withThrowingTaskGroup(of: InboxMessage?.self) { group in
            for id in newIDs {
                let source = sourceByID[id] ?? .gmail
                group.addTask {
                    var message = try await api.message(id: id)
                    message?.source = source.rawValue
                    return message
                }
            }
            var result: [InboxMessage] = []
            for try await message in group { if let message { result.append(message) } }
            return result
        }

        let drafts = try await client.analyze(messages, source: .gmail)
        AnalyzedLog.gmail.insert(newIDs)

        // sourceID 形如 "gmail:<邮件id>#0"，用邮件 id 找回来源、拼出网页版链接
        return drafts.map { draft in
            var draft = draft
            let messageID = draft.sourceID.dropFirst("gmail:".count).split(separator: "#").first.map(String.init) ?? ""
            draft.source = sourceByID[messageID] ?? .gmail
            draft.link = "https://mail.google.com/mail/u/0/#all/\(messageID)"
            return draft
        }
    }
}

// MARK: - Gmail REST API

struct GmailAPI: Sendable {
    var accessToken: String
    private let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!

    func profileEmail() async throws -> String {
        struct Profile: Decodable { var emailAddress: String }
        return try await get("profile", as: Profile.self).emailAddress
    }

    func listMessageIDs(query: String, max: Int) async throws -> [String] {
        struct List: Decodable {
            struct Ref: Decodable { var id: String }
            var messages: [Ref]?
        }
        let list = try await get("messages", query: ["q": query, "maxResults": String(max)], as: List.self)
        return list.messages?.map(\.id) ?? []
    }

    /// 取一封邮件的发件人、标题、时间和纯文本正文
    func message(id: String) async throws -> InboxMessage? {
        let raw = try await get("messages/\(id)", query: ["format": "full"], as: GmailMessage.self)
        let headers = raw.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        let body = raw.payload.map(Self.plainText(from:)) ?? ""
        return InboxMessage(
            id: "gmail:\(raw.id)",
            source: "gmail",
            from: header("From"),
            subject: header("Subject"),
            receivedAt: Date(timeIntervalSince1970: (Double(raw.internalDate ?? "") ?? 0) / 1000),
            body: body.isEmpty ? (raw.snippet ?? "") : body
        )
    }

    // MARK: 解析正文

    struct GmailMessage: Decodable {
        var id: String
        var snippet: String?
        var internalDate: String?
        var payload: Part?
    }

    struct Part: Decodable {
        struct Header: Decodable { var name: String; var value: String }
        struct Body: Decodable { var data: String? }
        var mimeType: String?
        var headers: [Header]?
        var body: Body?
        var parts: [Part]?
    }

    /// 优先取 text/plain；没有的话把 text/html 去掉标签
    static func plainText(from part: Part) -> String {
        if let text = firstBody(in: part, mimeType: "text/plain"), !text.isEmpty { return text }
        if let html = firstBody(in: part, mimeType: "text/html") { return stripHTML(html) }
        return ""
    }

    private static func firstBody(in part: Part, mimeType: String) -> String? {
        if part.mimeType == mimeType, let data = part.body?.data, let decoded = Data(base64URLEncoded: data) {
            return String(decoding: decoded, as: UTF8.self)
        }
        for child in part.parts ?? [] {
            if let found = firstBody(in: child, mimeType: mimeType) { return found }
        }
        return nil
    }

    static func stripHTML(_ html: String) -> String {
        html
            .replacingOccurrences(of: "<(style|script)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</tr>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 请求

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type) async throws -> T {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GoogleAuth.AuthError.server("Gmail \(code)：\(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - 已分析记录

/// 记住哪些邮件已经交给 Claude 分析过，避免每次同步都重复花钱
struct AnalyzedLog: Sendable {
    let key: String
    var limit = 1000

    static let gmail = AnalyzedLog(key: "analyzed.gmail")
    /// 邮件自动记账已经处理过的收据
    static let charges = AnalyzedLog(key: "analyzed.charges")

    func contains(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(id)
    }

    func insert(_ ids: [String]) {
        var all = UserDefaults.standard.stringArray(forKey: key) ?? []
        all.append(contentsOf: ids.filter { !all.contains($0) })
        UserDefaults.standard.set(Array(all.suffix(limit)), forKey: key)
    }

    func reset() { UserDefaults.standard.removeObject(forKey: key) }
}
