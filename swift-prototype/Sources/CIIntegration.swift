import Foundation
import Security

// MARK: - Secure credentials

/// 只保存令牌，不把任何凭据写入普通配置文件。
final class KeychainVault {
    static let shared = KeychainVault()
    private let service = "com.stackhub.prototype.credentials"
    // Security.framework is synchronous, and the same vault is queried by
    // SwiftUI rendering as well as CI refresh tasks. Serialize the calls so
    // the framework never observes overlapping access to the same item.
    private let lock = NSLock()

    private init() {}

    func save(token: String, account: String) throws {
        try save(data: Data(token.utf8), account: account)
    }

    func save(data: Data, account: String) throws {
        try withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
            let attributes = query.merging([kSecValueData as String: data]) { _, new in new }
            let status = SecItemAdd(attributes as CFDictionary, nil)
            guard status == errSecSuccess else { throw CIIntegrationError.keychain(status) }
        }
    }

    func read(account: String) -> String? {
        guard let data = readData(account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func readData(account: String) -> Data? {
        withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let result,
                  CFGetTypeID(result) == CFDataGetTypeID() else { return nil }
            // Copy the framework-owned buffer before releasing the CF result.
            return Data(result as! CFData as Data)
        }
    }

    func delete(account: String) {
        withLock {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

enum CIIntegrationError: LocalizedError {
    case invalidURL
    case http(Int, String)
    case keychain(OSStatus)
    case missingToken

    var errorDescription: String? {
        switch self {
        case .invalidURL: return L("服务地址无效")
        case let .http(code, message): return LF("接口请求失败（%ld）%@", code, message)
        case .keychain: return L("凭据保存失败")
        case .missingToken: return L("尚未配置访问令牌")
        }
    }
}

/// Keeps execution-time values compact and consistent across GitHub Actions
/// and GitLab CI. The APIs return seconds (or, for GitHub, start/end dates),
/// while the UI should not expose decimal seconds such as "12.0 秒".
enum CIExecutionTimeFormatter {
    static func duration(seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }

        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            return minutes > 0 ? LF("%ld 小时 %ld 分钟", hours, minutes) : LF("%ld 小时", hours)
        }
        if minutes > 0 {
            return remainingSeconds > 0 ? LF("%ld 分 %ld 秒", minutes, remainingSeconds) : LF("%ld 分钟", minutes)
        }
        return LF("%ld 秒", remainingSeconds)
    }

    static func duration(from start: Date?, to end: Date?) -> String {
        guard let start, let end else { return "—" }
        return duration(seconds: max(0, end.timeIntervalSince(start)))
    }
}

// MARK: - API DTOs

struct RemoteProject: Identifiable, Decodable {
    let id: String
    let name: String
    let repository: String
    let branch: String
    let provider: String
    let instanceName: String?
    let updatedAt: Date?
}

struct RemotePipeline: Identifiable, Decodable {
    let id: String
    let projectID: String
    let provider: String
    let repository: String
    let branch: String
    let commit: String
    let status: String
    let duration: String
    let webURL: String?
    let updatedAt: Date?
    let startedAt: Date?

    var state: PipelineState {
        switch status.lowercased() {
        case "success", "passed", "completed": return .success
        case "running", "in_progress", "in progress", "pending", "queued": return .running
        default: return .failed
        }
    }
}

struct RemoteJob: Identifiable, Decodable {
    let id: String
    let name: String
    let stage: String
    let status: String
    let duration: String
    let log: String

    var state: PipelineState {
        switch status.lowercased() {
        case "success", "passed", "completed": return .success
        case "running", "in_progress", "pending", "queued": return .running
        default: return .failed
        }
    }
}

// MARK: - GitHub REST

final class GitHubAPIClient {
    /// GitHub has no cross-repository Actions feed, so keep the sync scope small.
    /// Repositories are returned newest-first by the API's `updated` sort.
    static let recentRepositoryLimit = 8

    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(token: String, session: URLSession = CIHTTPTransport.session) {
        self.token = token
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Returns only the most recently updated repositories owned by the
    /// authenticated GitHub user. `affiliation=owner` intentionally excludes
    /// collaborator and organization repositories, and a single page avoids
    /// walking a potentially very large repository list.
    func ownedProjects(limit: Int = GitHubAPIClient.recentRepositoryLimit, since: Date? = nil) async throws -> [RemoteProject] {
        let pageSize = min(max(limit, 1), 100)
        var query = [
            URLQueryItem(name: "per_page", value: "\(pageSize)"),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "affiliation", value: "owner")
        ]
        if let since {
            query.append(URLQueryItem(name: "since", value: Self.iso8601Formatter.string(from: since)))
        }
        let url = try makeURL(path: "/user/repos", query: query)
        let response: [GitHubRepository] = try await send(url)
        return response.prefix(pageSize).map {
            RemoteProject(id: "github:\($0.fullName)", name: $0.name, repository: $0.fullName, branch: $0.defaultBranch ?? "main", provider: "GitHub Actions", instanceName: nil, updatedAt: $0.updatedAt)
        }
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func recentRuns(owner: String, repository: String, projectID: String) async throws -> [RemotePipeline] {
        let url = try makeURL(path: "/repos/\(owner)/\(repository)/actions/runs", query: [URLQueryItem(name: "per_page", value: "5")])
        let response: GitHubWorkflowRunsResponse = try await send(url)
        return response.workflowRuns.map {
            RemotePipeline(
                id: "github-\($0.id)", projectID: projectID, provider: "GitHub Actions", repository: "\(owner)/\(repository)",
                branch: $0.headBranch ?? "main", commit: "\(String($0.headSHA.prefix(7))) · GitHub", status: $0.conclusion ?? $0.status,
                duration: CIExecutionTimeFormatter.duration(from: $0.runStartedAt, to: $0.updatedAt),
                webURL: $0.htmlURL, updatedAt: $0.updatedAt, startedAt: $0.runStartedAt
            )
        }
    }

    func jobs(owner: String, repository: String, runID: String) async throws -> [RemoteJob] {
        let url = try makeURL(path: "/repos/\(owner)/\(repository)/actions/runs/\(runID)/jobs", query: [URLQueryItem(name: "per_page", value: "100")])
        let response: GitHubJobsResponse = try await send(url)
        return response.jobs.map {
            RemoteJob(id: "github-job-\($0.id)", name: $0.name, stage: $0.name, status: $0.conclusion ?? $0.status, duration: "—", log: "")
        }
    }

    func jobLog(owner: String, repository: String, jobID: String) async throws -> String {
        let url = try makeURL(path: "/repos/\(owner)/\(repository)/actions/jobs/\(jobID)/logs")
        var request = URLRequest(url: url, timeoutInterval: CIHTTPTransport.timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CIIntegrationError.http(-1, "无效响应") }
        guard 200..<300 ~= http.statusCode else { throw CIIntegrationError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        // GitHub returns a ZIP archive for this endpoint. Keep a plain-text
        // fallback for compatible GitHub Enterprise implementations.
        if data.starts(with: [0x50, 0x4B]) {
            return try unzipLog(data)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func unzipLog(_ data: Data) throws -> String {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("stackhub-github-log-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("logs.zip")
        try data.write(to: archive, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "无法解压 GitHub 作业日志"
            throw CIIntegrationError.http(-1, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let files = (fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? [])
            .filter { $0.lastPathComponent != "logs.zip" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .sorted { $0.path < $1.path }
        return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func makeURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(string: "https://api.github.com")
        components?.path = path
        components?.queryItems = query
        guard let url = components?.url else { throw CIIntegrationError.invalidURL }
        return url
    }

    private func send<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: CIHTTPTransport.timeout)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CIIntegrationError.http(-1, "无效响应") }
        guard 200..<300 ~= http.statusCode else { throw CIIntegrationError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return try decoder.decode(T.self, from: data)
    }
}

private struct GitHubRepository: Decodable {
    let name: String
    let fullName: String
    let defaultBranch: String?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case defaultBranch = "default_branch"
        case updatedAt = "updated_at"
    }
}

private struct GitHubWorkflowRunsResponse: Decodable {
    let workflowRuns: [GitHubWorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct GitHubWorkflowRun: Decodable {
    let id: Int
    let status: String
    let conclusion: String?
    let headBranch: String?
    let headSHA: String
    let htmlURL: String?
    let updatedAt: Date?
    let runStartedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status, conclusion
        case headBranch = "head_branch"
        case headSHA = "head_sha"
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case runStartedAt = "run_started_at"
    }
}

private struct GitHubJobsResponse: Decodable {
    let jobs: [GitHubJob]
}

private struct GitHubJob: Decodable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
}

// MARK: - GitLab REST

final class GitLabAPIClient {
    /// Older/self-managed GitLab versions may not expose the cross-project
    /// `/pipelines` endpoint. Keep the compatibility fallback bounded.
    static let legacyFallbackProjectLimit = 8

    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let decoder: JSONDecoder
    private let projectIDPrefix: String?

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(instanceURL: String, token: String, session: URLSession = CIHTTPTransport.session, projectIDPrefix: String? = nil) throws {
        var normalized = instanceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.contains("://") { normalized = "https://\(normalized)" }
        if normalized.hasSuffix("/") { normalized = String(normalized.dropLast()) }
        guard let url = URL(string: normalized) else { throw CIIntegrationError.invalidURL }
        self.baseURL = url
        self.token = token
        self.session = session
        self.decoder = JSONDecoder()
        // GitLab commonly emits fractional seconds and timezone offsets
        // (for example `2026-09-12T12:34:56.123+08:00`), while the built-in
        // `.iso8601` strategy is not consistent across macOS releases for
        // those variants.
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "无法解析 GitLab 时间：\(value)"
            )
        }
        self.projectIDPrefix = projectIDPrefix
    }

    func accessibleProjects() async throws -> [RemoteProject] {
        var response: [GitLabProject] = []
        for page in 1...10 {
            let url = try makeURL(path: "/api/v4/projects", query: [
                URLQueryItem(name: "membership", value: "true"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: "\(page)"),
                URLQueryItem(name: "order_by", value: "last_activity_at")
            ])
            let batch: [GitLabProject] = try await send(url)
            response.append(contentsOf: batch)
            if batch.count < 100 { break }
        }
        return response.map {
            let prefix = projectIDPrefix ?? baseURL.host ?? "instance"
            return RemoteProject(id: "gitlab:\(prefix):\($0.id)", name: $0.name, repository: $0.pathWithNamespace, branch: $0.defaultBranch ?? "main", provider: "GitLab CI", instanceName: baseURL.host, updatedAt: nil)
        }
    }

    /// GitLab 的全局流水线活动接口。它一次返回多个项目的近期流水线，
    /// 由调用方根据 project_id 分组，避免对每个项目逐一请求。
    /// GitLab 官方定义该接口返回当前账号触发的近期流水线。
    func recentPipelines(limit: Int = 100, createdAfter: Date? = nil) async throws -> [RemotePipeline] {
        var query = [
            URLQueryItem(name: "per_page", value: "\(min(max(limit, 1), 100))"),
            URLQueryItem(name: "order_by", value: "created_at"),
            URLQueryItem(name: "sort", value: "desc")
        ]
        if let createdAfter {
            query.append(URLQueryItem(name: "created_after", value: Self.iso8601Formatter.string(from: createdAfter)))
        }
        let url = try makeURL(path: "/api/v4/pipelines", query: query)
        let response: [GitLabPipeline] = try await send(url)
        let prefix = projectIDPrefix ?? baseURL.host ?? "instance"
        return response.map { makeRemotePipeline($0, prefix: prefix) }
    }

    /// Resolves one project only when an older global-pipeline response does
    /// not include project metadata. This is deliberately not a project-list
    /// request, so supported GitLab instances never enumerate repositories.
    func project(projectID: String) async throws -> RemoteProject {
        let url = try makeURL(path: "/api/v4/projects/\(apiProjectID(projectID))")
        let response: GitLabProject = try await send(url)
        let prefix = projectIDPrefix ?? baseURL.host ?? "instance"
        return makeRemoteProject(response, prefix: prefix)
    }

    /// The global feed is incremental by creation time. Existing pipelines
    /// that are still running need this small direct refresh so their terminal
    /// state is not missed after they fall behind the creation cursor.
    func pipeline(projectID: String, pipelineID: String) async throws -> RemotePipeline {
        let url = try makeURL(path: "/api/v4/projects/\(apiProjectID(projectID))/pipelines/\(pipelineID)")
        let response: GitLabPipeline = try await send(url)
        let prefix = projectIDPrefix ?? baseURL.host ?? "instance"
        return makeRemotePipeline(response, prefix: prefix)
    }

    /// Compatibility path for GitLab versions without the global pipeline
    /// feed. `updated_after` lets callers retain a per-project cursor so
    /// already-indexed history is not transferred again on every poll.
    func recentPipelines(
        projectID: String,
        limit: Int = 5,
        updatedAfter: Date? = nil
    ) async throws -> [RemotePipeline] {
        var query = [
            URLQueryItem(name: "per_page", value: "\(min(max(limit, 1), 100))"),
            URLQueryItem(name: "order_by", value: "updated_at"),
            URLQueryItem(name: "sort", value: "desc")
        ]
        if let updatedAfter {
            query.append(URLQueryItem(name: "updated_after", value: Self.iso8601Formatter.string(from: updatedAfter)))
        }
        let url = try makeURL(path: "/api/v4/projects/\(apiProjectID(projectID))/pipelines", query: query)
        let response: [GitLabPipeline] = try await send(url)
        let prefix = projectIDPrefix ?? baseURL.host ?? "instance"
        return response.map { makeRemotePipeline($0, prefix: prefix) }
    }

    func jobs(projectID: String, pipelineID: String) async throws -> [RemoteJob] {
        let encoded = apiProjectID(projectID)
        let url = try makeURL(path: "/api/v4/projects/\(encoded)/pipelines/\(pipelineID)/jobs", query: [URLQueryItem(name: "per_page", value: "100")])
        let response: [GitLabJob] = try await send(url)
        return response.map {
            RemoteJob(id: "gitlab-job-\($0.id)", name: $0.name, stage: $0.stage, status: $0.status, duration: CIExecutionTimeFormatter.duration(seconds: $0.duration), log: "")
        }
    }

    func jobLog(projectID: String, jobID: String) async throws -> String {
        let url = try makeURL(path: "/api/v4/projects/\(apiProjectID(projectID))/jobs/\(jobID)/trace")
        var request = URLRequest(url: url, timeoutInterval: CIHTTPTransport.timeout)
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CIIntegrationError.http(-1, "无效响应") }
        guard 200..<300 ~= http.statusCode else { throw CIIntegrationError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func apiProjectID(_ projectID: String) -> String {
        projectID.split(separator: ":").last.map(String.init)?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? projectID
    }

    private func makeRemotePipeline(_ pipeline: GitLabPipeline, prefix: String) -> RemotePipeline {
        RemotePipeline(
            id: "gitlab-\(pipeline.id)", projectID: "gitlab:\(prefix):\(pipeline.projectID)", provider: "GitLab CI",
            repository: pipeline.project?.pathWithNamespace ?? "", branch: pipeline.ref,
            commit: "\(String(pipeline.sha.prefix(7))) · GitLab", status: pipeline.status,
            duration: CIExecutionTimeFormatter.duration(seconds: pipeline.duration),
            webURL: pipeline.webURL, updatedAt: pipeline.updatedAt ?? pipeline.createdAt, startedAt: pipeline.startedAt ?? pipeline.createdAt
        )
    }

    private func makeRemoteProject(_ project: GitLabProject, prefix: String) -> RemoteProject {
        RemoteProject(
            id: "gitlab:\(prefix):\(project.id)", name: project.name,
            repository: project.pathWithNamespace, branch: project.defaultBranch ?? "main",
            provider: "GitLab CI", instanceName: baseURL.host, updatedAt: nil
        )
    }


    private func makeURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw CIIntegrationError.invalidURL }
        components.path = path
        components.queryItems = query
        guard let url = components.url else { throw CIIntegrationError.invalidURL }
        return url
    }

    private func send<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: CIHTTPTransport.timeout)
        request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CIIntegrationError.http(-1, "无效响应") }
        guard 200..<300 ~= http.statusCode else { throw CIIntegrationError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        return try decoder.decode(T.self, from: data)
    }
}

private struct GitLabProject: Decodable {
    let id: Int
    let name: String
    let pathWithNamespace: String
    let defaultBranch: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case pathWithNamespace = "path_with_namespace"
        case defaultBranch = "default_branch"
    }
}

private struct GitLabPipeline: Decodable {
    let id: Int
    let projectID: Int
    let status: String
    let ref: String
    let sha: String
    let webURL: String?
    let duration: Double?
    let updatedAt: Date?
    let createdAt: Date?
    let startedAt: Date?
    let project: GitLabPipelineProject?

    enum CodingKeys: String, CodingKey {
        case id, status, ref, sha, duration, project
        case projectID = "project_id"
        case webURL = "web_url"
        case updatedAt = "updated_at"
        case createdAt = "created_at"
        case startedAt = "started_at"
    }
}

private struct GitLabPipelineProject: Decodable {
    let pathWithNamespace: String

    enum CodingKeys: String, CodingKey {
        case pathWithNamespace = "path_with_namespace"
    }
}

private struct GitLabJob: Decodable {
    let id: Int
    let name: String
    let stage: String
    let status: String
    let duration: Double?
}
