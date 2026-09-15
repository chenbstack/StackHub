import AppKit
import Foundation

enum GitHubOAuthConfiguration {
    static let defaultClientID = "Ov23limk6wh0mTL2nVDe"
    static let clientIDKey = "stackhub.github.oauth.client_id"
    static let accessTokenExpiryKey = "stackhub.github.oauth.access_token_expiry"
}

struct GitHubOAuthCredential {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
}

/// GitHub Device Flow controller for the menu-bar app.
///
/// Device Flow keeps a client secret out of the shipped native app. The user
/// finishes authorization in their browser, while this controller polls GitHub
/// until the access token is ready.
@MainActor
final class GitHubOAuthController: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case waiting(userCode: String, verificationURL: URL)
        case authorized
        case failed(String)
    }

    @Published var clientID: String {
        didSet { UserDefaults.standard.set(clientID.trimmingCharacters(in: .whitespacesAndNewlines), forKey: GitHubOAuthConfiguration.clientIDKey) }
    }
    @Published private(set) var state: State = .idle

    private let client: GitHubOAuthClient
    private var pollingTask: Task<Void, Never>?

    init(session: URLSession = .shared) {
        let savedClientID = UserDefaults.standard.string(forKey: GitHubOAuthConfiguration.clientIDKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        clientID = savedClientID?.isEmpty == false ? savedClientID! : GitHubOAuthConfiguration.defaultClientID
        client = GitHubOAuthClient(session: session)
    }

    var isRunning: Bool {
        switch state {
        case .starting, .waiting: return true
        default: return false
        }
    }

    var statusText: String? {
        switch state {
        case .idle: return nil
        case .starting: return L("正在向 GitHub 请求授权码…")
        case let .waiting(userCode, _): return LF("请在浏览器输入授权码 %@，完成后会自动同步。", userCode)
        case .authorized: return L("浏览器授权成功，Token 已保存到钥匙串。")
        case let .failed(message): return message
        }
    }

    var verificationURL: URL? {
        guard case let .waiting(_, url) = state else { return nil }
        return url
    }

    var verificationCode: String? {
        guard case let .waiting(code, _) = state else { return nil }
        return code
    }

    func start(onToken: @escaping @MainActor (GitHubOAuthCredential) -> Void) {
        cancel()
        let trimmedID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            state = .failed(L("请先填写 GitHub OAuth Client ID，并在 OAuth App 设置中开启 Device Flow。"))
            return
        }

        clientID = trimmedID
        state = .starting
        pollingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let device = try await self.client.requestDeviceCode(clientID: trimmedID)
                guard !Task.isCancelled else { return }
                let verification = device.verificationURIComplete ?? device.verificationURI
                await MainActor.run {
                    self.state = .waiting(userCode: device.userCode, verificationURL: verification)
                    NSWorkspace.shared.open(verification)
                }

                var interval = max(device.interval ?? 5, 5)
                let deadline = Date().addingTimeInterval(TimeInterval(device.expiresIn ?? 900))
                while !Task.isCancelled && Date() < deadline {
                    try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                    let result = try await self.client.pollAccessToken(clientID: trimmedID, deviceCode: device.deviceCode)
                    switch result {
                    case let .token(credential):
                        await MainActor.run {
                            self.state = .authorized
                            onToken(credential)
                        }
                        return
                    case .pending:
                        continue
                    case let .slowDown(nextInterval):
                        interval = max(nextInterval, interval + 5)
                    case let .failed(message):
                        await MainActor.run { self.state = .failed(message) }
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run { self.state = .failed(L("GitHub 授权码已过期，请重新开始浏览器授权。")) }
            } catch is CancellationError {
                // A new authorization attempt or cancel() intentionally stops polling.
            } catch {
                await MainActor.run { self.state = .failed(LF("GitHub 授权失败：%@", error.localizedDescription)) }
            }
        }
    }

    func openBrowser() {
        guard let url = verificationURL else { return }
        NSWorkspace.shared.open(url)
    }

    func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
        if isRunning { state = .idle }
    }
}

final class GitHubOAuthClient {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    fileprivate func requestDeviceCode(clientID: String) async throws -> DeviceCodeResponse {
        var request = URLRequest(url: URL(string: "https://github.com/login/device/code")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData(["client_id": clientID, "scope": "repo workflow read:user"])
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    fileprivate func pollAccessToken(clientID: String, deviceCode: String) async throws -> PollResult {
        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            "client_id": clientID,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CIIntegrationError.http(-1, "无效响应") }
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        if let token = payload.accessToken, !token.isEmpty {
            return .token(GitHubOAuthCredential(accessToken: token, refreshToken: payload.refreshToken, expiresIn: payload.expiresIn))
        }
        switch payload.error {
        case "authorization_pending": return .pending
        case "slow_down": return .slowDown(payload.interval ?? 5)
        case "expired_token", "token_expired": return .failed(L("GitHub 授权码已过期，请重新开始浏览器授权。"))
        case "access_denied": return .failed(L("你取消了 GitHub 授权。"))
        case "device_flow_disabled": return .failed(L("该 GitHub OAuth App 未开启 Device Flow。"))
        default:
            if let error = payload.errorDescription, !error.isEmpty { return .failed(error) }
            if !(200..<300).contains(http.statusCode) { return .failed(LF("GitHub 返回 HTTP %ld", http.statusCode)) }
            return .failed(L("GitHub 未返回访问令牌。"))
        }
    }

    func refreshAccessToken(clientID: String, refreshToken: String) async throws -> GitHubOAuthCredential {
        var request = URLRequest(url: URL(string: "https://github.com/login/oauth/access_token")!, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formData([
            "client_id": clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ])
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let token = payload.accessToken, !token.isEmpty else {
            throw CIIntegrationError.http(-1, payload.errorDescription ?? "GitHub 未返回刷新后的访问令牌")
        }
        return GitHubOAuthCredential(accessToken: token, refreshToken: payload.refreshToken ?? refreshToken, expiresIn: payload.expiresIn)
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw CIIntegrationError.http(-1, "无效响应") }
        guard 200..<300 ~= http.statusCode else {
            throw CIIntegrationError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func formData(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.keys.sorted().map { URLQueryItem(name: $0, value: values[$0]) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }
}

private struct DeviceCodeResponse: Decodable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let verificationURIComplete: URL?
    let expiresIn: Int?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let error: String?
    let errorDescription: String?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case error
        case errorDescription = "error_description"
        case interval
    }
}

private enum PollResult {
    case token(GitHubOAuthCredential)
    case pending
    case slowDown(Int)
    case failed(String)
}
