import Foundation
import XCTest
@testable import StackHub

final class CIJobPresentationTests: XCTestCase {
    func testProviderStatusesDoNotTurnWaitingOrTerminalNeutralStatesIntoFailures() {
        let cases: [(String, PipelineState)] = [
            ("created", .pending), ("pending", .pending), ("waiting_for_resource", .pending),
            ("waiting_for_callback", .pending), ("queued", .pending), ("preparing", .running),
            ("running", .running), ("in_progress", .running), ("canceling", .running),
            ("success", .success), ("failed", .failed), ("failure", .failed), ("timed_out", .failed),
            ("manual", .manual), ("scheduled", .scheduled), ("skipped", .skipped),
            ("canceled", .canceled), ("cancelled", .canceled), ("future_status", .unknown)
        ]
        for (status, expected) in cases {
            let job = RemoteJob(id: "job", name: "job", stage: "build", status: status, duration: "—", log: "")
            let pipeline = RemotePipeline(id: "run", projectID: "project", provider: "GitLab CI", repository: "team/app", branch: "main", commit: "", status: status, duration: "—", webURL: nil, updatedAt: nil, startedAt: nil)
            XCTAssertEqual(job.state, expected, status)
            XCTAssertEqual(pipeline.state, expected, status)
        }
    }

    func testStageAggregationDistinguishesWaitingSkippedAndFailed() {
        XCTAssertEqual(PipelineState.aggregate([.pending, .pending, .pending]), .pending)
        XCTAssertEqual(PipelineState.aggregate([.success, .pending]), .pending)
        XCTAssertEqual(PipelineState.aggregate([.running, .pending]), .running)
        XCTAssertEqual(PipelineState.aggregate([.failed, .pending]), .failed)
        XCTAssertEqual(PipelineState.aggregate([.skipped, .skipped]), .skipped)
        XCTAssertEqual(PipelineState.aggregate([.success, .skipped]), .success)
        XCTAssertEqual(PipelineState.aggregate([.manual]), .manual)
        XCTAssertEqual(PipelineState.aggregate([.canceled]), .canceled)
        XCTAssertEqual(PipelineState.aggregate([]), .unknown)
    }

    func testGitLabUsesDeclaredStageOrderEvenWhenTestJobHasBeenRetried() async throws {
        let host = "stages-\(UUID().uuidString).test"
        var graphRequests = 0
        let client = try client(host: host) { request in
            if request.url!.path == "/api/graphql" {
                graphRequests += 1
                let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                let variables = components.queryItems!.first { $0.name == "variables" }!.value!
                XCTAssertTrue(variables.contains("gid://gitlab/Ci::Pipeline/42") || variables.contains("gid:\\/\\/gitlab\\/Ci::Pipeline\\/42"))
                return (200, #"{"data":{"project":{"pipeline":{"stages":{"nodes":[{"name":"test"},{"name":"build"}]}}}}}"#)
            }
            return (200, #"[{"id":99,"name":"migration-test","stage":"test","status":"running"},{"id":14,"name":"docker-release: [custom]","stage":"build","status":"created"},{"id":13,"name":"docker-release: [agent]","stage":"build","status":"created"},{"id":12,"name":"docker-release: [admin]","stage":"build","status":"created"}]"#)
        }
        defer { CIJobStub.remove(host) }
        let jobs = try await client.jobs(projectID: "gitlab:instance:1", pipelineID: "42", repository: "team/app")
        let detailed = try XCTUnwrap(CIPipelineCache.withJobs(pipeline(state: .running), jobs: jobs))
        let groups = detailed.stages.groupedPipelineStages
        XCTAssertEqual(groups.map(\.name), ["test", "build"])
        XCTAssertEqual(groups.map(\.state), [.running, .pending])
        XCTAssertEqual(groups.last?.jobs.map(\.name), ["docker-release: [admin]", "docker-release: [agent]", "docker-release: [custom]"])
        _ = try await client.jobs(projectID: "gitlab:instance:1", pipelineID: "42", repository: "team/app")
        XCTAssertEqual(graphRequests, 1, "Stage metadata must be cached instead of fetched every refresh")
        let restored = try JSONDecoder().decode(Pipeline.self, from: JSONEncoder().encode(detailed))
        XCTAssertEqual(restored.stages.groupedPipelineStages.map(\.name), ["test", "build"])
        XCTAssertEqual(restored.stages.last?.rawStatus, "created")
    }

    func testUnsupportedStageMetadataKeepsJobsAndBacksOff() async throws {
        let host = "fallback-\(UUID().uuidString).test"
        var graphRequests = 0
        let client = try client(host: host) { request in
            if request.url!.path == "/api/graphql" { graphRequests += 1; return (404, "{}") }
            return (200, #"[{"id":2,"name":"build","stage":"build","status":"created"},{"id":1,"name":"test","stage":"test","status":"running"}]"#)
        }
        defer { CIJobStub.remove(host) }
        for _ in 0..<2 {
            let jobs = try await client.jobs(projectID: "1", pipelineID: "42", repository: "team/app")
            XCTAssertEqual(jobs.map(\.stage), ["test", "build"])
            XCTAssertEqual(jobs.map(\.state), [.running, .pending])
        }
        XCTAssertEqual(graphRequests, 1)
    }

    func testOldMisclassifiedCacheRefreshesOnceAndRetainsLogs() throws {
        let oldStage = PipelineStage(id: "job", name: "build", duration: "—", state: .failed, log: "cached log", group: "build")
        let old = pipeline(state: .success, stages: [oldStage], loaded: true)
        let json = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(Pipeline.self, from: json)
        XCTAssertEqual(CIPipelineCache.stageRefreshCandidates(in: ["project": [decoded]]).count, 1)
        let refreshed = try XCTUnwrap(CIPipelineCache.withJobs(decoded, jobs: [
            RemoteJob(id: "job", name: "build", stage: "build", status: "skipped", duration: "—", log: "", stageOrder: 1)
        ]))
        let merged = CIPipelineCache.merging(refreshed, with: decoded)
        XCTAssertEqual(merged.stages[0].state, .skipped)
        XCTAssertEqual(merged.stages[0].log, "cached log")
        XCTAssertEqual(merged.stages[0].rawStatus, "skipped")
        XCTAssertEqual(merged.stages[0].groupOrder, 1)
        XCTAssertTrue(CIPipelineCache.stageRefreshCandidates(in: ["project": [merged]]).isEmpty)
    }

    func testWaitingPipelineStillGetsPolledWithoutCountingAsFailure() {
        for state in [PipelineState.pending, .manual, .scheduled, .unknown] {
            let run = pipeline(state: state)
            XCTAssertTrue(state.needsStatusRefresh)
            XCTAssertEqual(CIPipelineCache.stageRefreshCandidates(in: ["project": [run]]).count, 1)
            XCTAssertEqual(CIPipelineStatusCounter.counts(in: [run], acknowledgedFailureIDs: []).unreadFailures, 0)
        }
    }

    private func pipeline(state: PipelineState, stages: [PipelineStage] = [], loaded: Bool = false) -> Pipeline {
        Pipeline(id: "gitlab-42", projectID: "project", provider: "GitLab CI", repository: "team/app", branch: "main", commit: "", duration: "—", state: state, stages: stages, updatedAt: nil, webURL: nil, hasLoadedStages: loaded, stageSnapshotState: state)
    }

    private func client(host: String, response: @escaping (URLRequest) -> (Int, String)) throws -> GitLabAPIClient {
        CIJobStub.install(host, response: response)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CIJobStub.self]
        return try GitLabAPIClient(instanceURL: "https://\(host)", token: "fixture-token", session: URLSession(configuration: configuration))
    }
}

private final class CIJobStub: URLProtocol {
    private static let lock = NSLock()
    private static var responses: [String: (URLRequest) -> (Int, String)] = [:]
    static func install(_ host: String, response: @escaping (URLRequest) -> (Int, String)) {
        lock.lock(); defer { lock.unlock() }; responses[host.lowercased()] = response
    }
    static func remove(_ host: String) {
        lock.lock(); defer { lock.unlock() }; responses.removeValue(forKey: host.lowercased())
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.responses[request.url!.host!.lowercased()]
        Self.lock.unlock()
        guard let handler else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
