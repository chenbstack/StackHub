import Foundation
import XCTest
@testable import StackHub

final class CIRefreshIsolationTests: XCTestCase {
    @MainActor
    func testHealthyInstancePublishesAndRefreshesAgainWhileOfficeIsWaiting() async throws {
        let office = instance("office")
        let online = instance("online")
        var now = Date()
        let scheduler = CIRefreshScheduler(now: { now })
        let fixture = makeFixture(instances: [office, online], scheduler: scheduler)
        defer { fixture.cleanUp() }
        let cached = cachedProject(office, number: 99)
        fixture.store.accessibleCIProjects = [cached]
        fixture.store.pipelineCache[cached.id] = [cachedPipeline(cached)]
        fixture.router.respond { request in
            if request.url!.host == "office.test" { return .hold }
            return .json(request.url!.path.hasSuffix("/jobs") ? "[]" : self.pipelineJSON())
        }

        fixture.store.refreshCI()
        let onlineID = "gitlab:\(online.id.uuidString):1"
        try await eventually {
            fixture.router.count(host: "office.test") == 1 &&
            fixture.store.pipelineCache[onlineID]?.first?.hasLoadedStages == false &&
            fixture.store.accessibleCIProjects.contains { $0.id == onlineID }
        }
        // Wait for the online task to complete its jobs request as well.
        try await eventually { !scheduler.isRefreshing(.gitlab(online.id)) }
        XCTAssertTrue(fixture.store.isRefreshingCI)
        XCTAssertEqual(fixture.store.pipelineCache[cached.id]?.first?.id, "cached")

        // Repeated refresh clicks don't start duplicate requests for office.
        fixture.router.respond { request in
            if request.url!.host == "office.test" { return .hold }
            return .json(request.url!.path.hasSuffix("/jobs") ? "[]" : self.pipelineJSON(run: 2))
        }
        now.addTimeInterval(31)
        fixture.store.refreshCIIfNeeded()
        fixture.store.refreshCI()
        try await eventually { fixture.store.pipelineCache[onlineID]?.first?.id == "gitlab-2" }
        XCTAssertEqual(fixture.router.count(host: "office.test"), 1)
        fixture.router.releaseHeld(host: "office.test", result: .failure(.timedOut))
        try await eventually { !fixture.store.isRefreshingCI }

        XCTAssertEqual(fixture.store.pipelineCache[onlineID]?.first?.id, "gitlab-2")
        XCTAssertEqual(fixture.store.pipelineCache[cached.id]?.first?.id, "cached")
        XCTAssertTrue(fixture.store.ciError?.contains("office") == true)
        let reloaded = StackHubStore(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.pipelineCache[cached.id]?.first?.id, "cached")
        XCTAssertEqual(reloaded.pipelineCache[onlineID]?.first?.id, "gitlab-2")
    }

    @MainActor
    func testLegacyOfflineInstanceStopsAfterFirstProjectTimeoutAndManualRetryRecovers() async throws {
        let office = instance("office")
        var now = Date()
        let scheduler = CIRefreshScheduler(now: { now })
        let fixture = makeFixture(instances: [office], scheduler: scheduler)
        defer { fixture.cleanUp() }
        let cached = (1...8).map { cachedProject(office, number: $0) }
        fixture.store.accessibleCIProjects = cached
        fixture.store.pipelineCache = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, [cachedPipeline($0)]) })
        fixture.router.respond { request in
            request.url!.path == "/api/v4/pipelines" ? .http(404) : .failure(.timedOut)
        }

        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.router.count(host: "office.test"), 2, "One capability probe and one failed project request")
        XCTAssertEqual(fixture.store.pipelineCache.count, 8)
        XCTAssertEqual(fixture.store.pipelineCache.values.flatMap { $0 }.map(\.id), Array(repeating: "cached", count: 8))
        let cursors = fixture.defaults.data(forKey: "stackhub.ci.gitlab-project-pipeline-sync-dates")
        XCTAssertTrue(try JSONDecoder().decode([String: Date].self, from: XCTUnwrap(cursors)).isEmpty)

        now = now.addingTimeInterval(31)
        fixture.store.refreshCIIfNeeded()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.router.count(host: "office.test"), 2, "Automatic refresh respects this instance's cooldown")

        fixture.router.respond { request in
            request.url!.path.hasSuffix("/jobs") ? .json("[]") : .json(self.pipelineJSON())
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertNil(fixture.store.ciError)
        XCTAssertTrue(fixture.store.pipelineCache.values.flatMap { $0 }.contains { $0.id == "gitlab-1" })
        XCTAssertEqual(fixture.router.requests.filter { $0.url!.path == "/api/v4/pipelines" }.count, 1, "Keep the confirmed legacy capability across offline attempts")
    }

    @MainActor
    func testJobTimeoutStopsPrefetchButKeepsAllNewSummaries() async throws {
        let office = instance("office")
        let fixture = makeFixture(instances: [office])
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            request.url!.path.hasSuffix("/jobs") ? .failure(.cannotConnectToHost) : .json(self.pipelineJSON(count: 8))
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.router.count(host: "office.test"), 2)
        XCTAssertEqual(fixture.store.accessibleCIProjects.count, 8)
        XCTAssertEqual(fixture.store.pipelineCache.count, 8)
        XCTAssertTrue(fixture.store.ciError?.contains("office") == true)
        XCTAssertTrue(fixture.router.requests.allSatisfy { $0.timeoutInterval == 3 })
    }

    @MainActor
    func testSlowSuccessfulInstanceDoesNotReplaceOtherInstancesNewerResults() async throws {
        var first = instance("first")
        var second = instance("second")
        first.name = "Same display name"
        second.name = "Same display name"
        let fixture = makeFixture(instances: [first, second])
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.host == "first.test" && request.url!.path == "/api/v4/pipelines" { return .hold }
            return .json(request.url!.path.hasSuffix("/jobs") ? "[]" : self.pipelineJSON(run: 2))
        }
        fixture.store.refreshCI()
        let secondID = "gitlab:\(second.id.uuidString):1"
        try await eventually { fixture.store.pipelineCache[secondID]?.first?.id == "gitlab-2" }
        fixture.router.releaseHeld(host: "first.test", result: .json(pipelineJSON(run: 1)))
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.accessibleCIProjects.count, 2)
        XCTAssertEqual(fixture.store.pipelineCache[secondID]?.first?.id, "gitlab-2")
        XCTAssertEqual(fixture.store.pipelineCache["gitlab:\(first.id.uuidString):1"]?.first?.id, "gitlab-1")
    }

    @MainActor
    func testWaitingGitHubDoesNotDelayGitLab() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.host == "api.github.com" { return .hold }
            return .json(request.url!.path.hasSuffix("/jobs") ? "[]" : self.pipelineJSON())
        }
        fixture.store.refreshCI()
        try await eventually {
            fixture.router.count(host: "api.github.com") == 1 && fixture.store.pipelineCache.count == 1
        }
        XCTAssertTrue(fixture.store.isRefreshingCI)
        fixture.router.releaseHeld(host: "api.github.com", result: .failure(.cannotFindHost))
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.pipelineCache.count, 1)
        XCTAssertTrue(fixture.store.ciError?.contains("GitHub") == true)
    }

    @MainActor
    func testAutomaticScheduleIsIndependentAndRecoveryClearsBackoff() throws {
        var now = Date(timeIntervalSince1970: 1_000)
        let scheduler = CIRefreshScheduler(now: { now })
        let office = CISource.gitlab(UUID())
        let online = CISource.gitlab(UUID())
        let waiting = try XCTUnwrap(scheduler.begin(office, manual: false))
        let firstOnline = try XCTUnwrap(scheduler.begin(online, manual: false))
        scheduler.finish(online, requestID: firstOnline, connectionFailed: false)
        now.addTimeInterval(30)
        XCTAssertNotNil(scheduler.begin(online, manual: false), "An in-flight source cannot lock other sources' timers")
        XCTAssertNil(scheduler.begin(office, manual: true), "Manual refresh deduplicates requests already in flight")
        scheduler.finish(office, requestID: waiting, connectionFailed: true)
        now.addTimeInterval(59)
        XCTAssertNil(scheduler.begin(office, manual: false))
        now.addTimeInterval(1)
        let retry = try XCTUnwrap(scheduler.begin(office, manual: false))
        scheduler.finish(office, requestID: retry, connectionFailed: true)
        now.addTimeInterval(119)
        XCTAssertNil(scheduler.begin(office, manual: false))
        let manual = try XCTUnwrap(scheduler.begin(office, manual: true))
        scheduler.finish(office, requestID: manual, connectionFailed: false)
        now.addTimeInterval(30)
        let recovered = try XCTUnwrap(scheduler.begin(office, manual: false))
        scheduler.invalidate(office)
        XCTAssertFalse(scheduler.isCurrent(office, requestID: recovered))
        let replacement = try XCTUnwrap(scheduler.begin(office, manual: false))
        scheduler.finish(office, requestID: recovered, connectionFailed: true)
        XCTAssertTrue(scheduler.isCurrent(office, requestID: replacement), "A stale response cannot finish a new refresh")
    }

    func testOfflineDetectionDoesNotTreatProjectPermissionErrorsAsOffline() {
        for code: URLError.Code in [.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet] {
            XCTAssertTrue(CIConnectionFailure.isOffline(URLError(code)))
        }
        XCTAssertFalse(CIConnectionFailure.isOffline(CIIntegrationError.http(403, "No permission")))
        XCTAssertFalse(CIConnectionFailure.isOffline(CIIntegrationError.http(404, "Not found")))
        XCTAssertTrue(CIConnectionFailure.shouldStopRequests(CancellationError()))
        XCTAssertFalse(CIHTTPTransport.session.configuration.waitsForConnectivity)
        XCTAssertEqual(CIHTTPTransport.session.configuration.timeoutIntervalForRequest, 3)
        XCTAssertEqual(CIHTTPTransport.session.configuration.timeoutIntervalForResource, 3)
    }

    func testRealNonRespondingServerTimesOutInThreeSeconds() async throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["-rsocket", "-e", "server = TCPServer.new('127.0.0.1', 0); puts server.addr[1]; STDOUT.flush; loop { socket = server.accept; Thread.new(socket) { |client| sleep 10; client.close } }"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let portText = String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = try XCTUnwrap(Int(portText))
        let client = try GitLabAPIClient(instanceURL: "http://127.0.0.1:\(port)", token: "test-only")
        let started = Date()
        do {
            _ = try await client.recentPipelines()
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 2.5)
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
    }

    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    private func instance(_ name: String) -> GitLabInstance {
        GitLabInstance(id: UUID(), name: name, host: "https://\(name).test", project: "")
    }

    private func cachedProject(_ instance: GitLabInstance, number: Int) -> CIAccessibleProject {
        CIAccessibleProject(id: "gitlab:\(instance.id.uuidString):\(number)", name: "Cached", provider: "GitLab CI", repository: "team/cached", branch: "main", instanceName: instance.name)
    }

    private func cachedPipeline(_ project: CIAccessibleProject) -> Pipeline {
        Pipeline(id: "cached", projectID: project.id, provider: "GitLab CI", repository: project.repository, branch: "main", commit: "cached", duration: "1 sec", state: .success, stages: [], updatedAt: Date(timeIntervalSince1970: 0), webURL: nil)
    }

    private func pipelineJSON(run: Int = 1, count: Int = 1) -> String {
        "[" + (1...count).map { project in
            """
            {"id":\(run),"project_id":\(project),"status":"success","ref":"main","sha":"abcdef123","duration":2,"updated_at":"2026-09-15T10:00:0\(run)Z","project":{"name":"Project \(project)","path_with_namespace":"team/project\(project)"}}
            """
        }.joined(separator: ",") + "]"
    }

    @MainActor
    private func makeFixture(instances: [GitLabInstance], scheduler: CIRefreshScheduler? = nil, githubToken: String? = nil) -> Fixture {
        let suiteName = "StackHub.CIRefreshTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        let router = CIStubRouter()
        CIStubProtocol.router = router
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CIStubProtocol.self]
        let session = URLSession(configuration: configuration)
        let store = StackHubStore(defaults: defaults, ciSession: session, ciCredentialProvider: CICredentialProvider(github: { githubToken }, gitlab: { _ in "test-token" }), ciRefreshScheduler: scheduler)
        store.instances = instances
        return Fixture(store: store, router: router, defaults: defaults, suiteName: suiteName, session: session)
    }

    @MainActor
    private struct Fixture {
        let store: StackHubStore
        let router: CIStubRouter
        let defaults: UserDefaults
        let suiteName: String
        let session: URLSession
        func cleanUp() {
            session.invalidateAndCancel()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

private enum CIStubResult {
    case json(String)
    case http(Int)
    case failure(URLError.Code)
    case hold
}

private final class CIStubRouter {
    private let lock = NSLock()
    private var handler: (URLRequest) -> CIStubResult = { _ in .json("[]") }
    private var recorded: [URLRequest] = []
    private var held: [CIStubProtocol] = []

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func count(host: String) -> Int { requests.filter { $0.url?.host == host }.count }
    func respond(_ handler: @escaping (URLRequest) -> CIStubResult) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
    }
    func receive(_ request: CIStubProtocol) {
        lock.lock()
        recorded.append(request.request)
        let result = handler(request.request)
        if case .hold = result { held.append(request) }
        lock.unlock()
        request.complete(result)
    }
    func releaseHeld(host: String, result: CIStubResult) {
        lock.lock()
        let pending = held.filter { $0.request.url?.host == host }
        held.removeAll { $0.request.url?.host == host }
        lock.unlock()
        pending.forEach { $0.complete(result) }
    }
}

private final class CIStubProtocol: URLProtocol {
    private static let routerLock = NSLock()
    private static var storedRouter = CIStubRouter()
    static var router: CIStubRouter {
        get { routerLock.lock(); defer { routerLock.unlock() }; return storedRouter }
        set { routerLock.lock(); defer { routerLock.unlock() }; storedRouter = newValue }
    }
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.router.receive(self) }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
    func complete(_ result: CIStubResult) {
        if case .hold = result { return }
        stateLock.lock()
        guard !stopped else { stateLock.unlock(); return }
        stopped = true
        stateLock.unlock()
        switch result {
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .json(let json): send(status: 200, body: json)
        case .http(let status): send(status: status, body: "[]")
        case .hold: break
        }
    }
    private func send(status: Int, body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
