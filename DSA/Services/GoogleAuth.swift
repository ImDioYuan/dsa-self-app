import AuthenticationServices
import CryptoKit
import Foundation
import SwiftUI

/// Google OAuth（iOS 类型客户端 + PKCE，不需要 client secret）
/// 令牌存在钥匙串里；访问令牌过期时用刷新令牌自动续期。
enum GoogleAuth {
    static let scope = "https://www.googleapis.com/auth/gmail.readonly"

    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    private static let keychainKey = "googleTokens"

    struct Tokens: Codable, Sendable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Date
        var email: String?
    }

    enum AuthError: LocalizedError {
        case missingClientID
        case cancelled
        case noRefreshToken
        case server(String)

        var errorDescription: String? {
            switch self {
            case .missingClientID: "请先在设置里填写 Google OAuth Client ID"
            case .cancelled: "已取消登录"
            case .noRefreshToken: "Google 登录已失效，请在设置里重新登录 Gmail"
            case let .server(message): "Google 返回错误：\(message)"
            }
        }
    }

    // MARK: - 状态

    static var clientID: String? {
        let raw = UserDefaults.standard.string(forKey: SettingsKey.googleClientID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw?.isEmpty == false ? raw : nil
    }

    static var tokens: Tokens? {
        get { Keychain.read(keychainKey).flatMap { try? JSONDecoder().decode(Tokens.self, from: Data($0.utf8)) } }
        set {
            let json = newValue.flatMap { try? JSONEncoder().encode($0) }.map { String(decoding: $0, as: UTF8.self) }
            Keychain.write(keychainKey, value: json)
        }
    }

    static var isSignedIn: Bool { tokens != nil }

    /// 自己退出（不用再提醒重新登录）
    static func signOut() {
        tokens = nil
        isExpired = false
    }

    /// 登录过期了：测试模式下刷新令牌 7 天就失效。只靠同步时的错误提示很容易错过，
    /// 而过期后邮件里的待办和邮件自动记账都会悄悄停掉，所以记下来，今日页一直提醒到重新登录
    static var isExpired: Bool {
        get { UserDefaults.standard.double(forKey: SettingsKey.gmailExpiredAt) > 0 }
        set {
            if newValue {
                UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: SettingsKey.gmailExpiredAt)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.gmailExpiredAt)
            }
        }
    }

    /// "123-abc.apps.googleusercontent.com" → "com.googleusercontent.apps.123-abc"
    static func callbackScheme(for clientID: String) -> String {
        let id = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(id)"
    }

    // MARK: - 登录

    /// 打开 Google 登录页，换取令牌并保存
    @MainActor
    static func signIn(using session: WebAuthenticationSession) async throws {
        guard let clientID else { throw AuthError.missingClientID }
        let scheme = callbackScheme(for: clientID)
        let redirectURI = "\(scheme):/oauth2redirect"

        let verifier = randomURLSafeString(length: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = randomURLSafeString(length: 24)

        var components = URLComponents(url: authEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "\(scope) email"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            // 让 Google 每次都返回 refresh_token
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]

        let callback: URL
        do {
            callback = try await session.authenticate(using: components.url!, callbackURLScheme: scheme)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            throw AuthError.cancelled
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value { throw AuthError.server(error) }
        guard items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value else {
            throw AuthError.server("回调参数不正确")
        }

        let response = try await tokenRequest([
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ])
        guard let refreshToken = response.refresh_token else { throw AuthError.noRefreshToken }

        var newTokens = Tokens(
            accessToken: response.access_token,
            refreshToken: refreshToken,
            expiresAt: .now.addingTimeInterval(TimeInterval(response.expires_in - 60))
        )
        newTokens.email = try? await GmailAPI(accessToken: newTokens.accessToken).profileEmail()
        tokens = newTokens
        isExpired = false
    }

    // MARK: - 访问令牌

    /// 返回有效的访问令牌，快过期时自动刷新
    static func validAccessToken() async throws -> String {
        guard var current = tokens else { throw AuthError.noRefreshToken }
        if current.expiresAt > .now { return current.accessToken }
        guard let clientID else { throw AuthError.missingClientID }

        do {
            let response = try await tokenRequest([
                "client_id": clientID,
                "refresh_token": current.refreshToken,
                "grant_type": "refresh_token",
            ])
            current.accessToken = response.access_token
            current.expiresAt = .now.addingTimeInterval(TimeInterval(response.expires_in - 60))
            tokens = current
            return current.accessToken
        } catch AuthError.server(let message) where message.contains("invalid_grant") {
            // 测试模式下刷新令牌 7 天过期，或者用户撤销了授权。今日页的 @AppStorage 在看这个值，放到主线程改
            await MainActor.run {
                signOut()
                isExpired = true
            }
            throw AuthError.noRefreshToken
        }
    }

    // MARK: - 工具

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int
        var refresh_token: String?
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((body.percentEncodedQuery ?? "").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.server(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return String(Data(bytes).base64URLEncoded().prefix(length))
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }
}
