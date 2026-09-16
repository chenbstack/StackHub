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
        XCTAssertEqual(fixture.router.count(host: "office.test"), 2, "One capability probe and one failed activity-index request")
        XCTAssertEqual(fixture.store.pipelineCache.count, 8)
        XCTAssertEqual(fixture.store.pipelineCache.values.flatMap { $0 }.map(\.id), Array(repeating: "cached", count: 8))
        let cursors = fixture.defaults.data(forKey: "stackhub.ci.gitlab-project-pipeline-sync-dates")
        XCTAssertTrue(try JSONDecoder().decode([String: Date].self, from: XCTUnwrap(cursors)).isEmpty)

        now = now.addingTimeInterval(31)
        fixture.store.refreshCIIfNeeded()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.router.count(host: "office.test"), 2, "Automatic refresh respects this instance's cooldown")

        fixture.router.respond { request in
            if request.url!.path == "/api/v4/projects" { return .json("[]") }
            return request.url!.path.hasSuffix("/jobs") ? .json("[]") : .json(self.pipelineJSON())
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertNil(fixture.store.ciError)
        XCTAssertTrue(fixture.store.pipelineCache.values.flatMap { $0 }.contains { $0.id == "gitlab-1" })
        XCTAssertEqual(fixture.router.requests.filter { $0.url!.path == "/api/v4/pipelines" }.count, 1, "Keep the confirmed legacy capability across offline attempts")
    }

    @MainActor
    func testLegacyRefreshFindsCEBeyondCachedPrefixBeforeAnotherProjectTimesOut() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online])
        defer { fixture.cleanUp() }
        let cached = (1...12).map { cachedProject(online, number: $0) }
        fixture.store.accessibleCIProjects = cached
        fixture.store.pipelineCache[cached[11].id] = [cachedPipeline(cached[11])]
        fixture.router.respond { request in
            switch request.url!.path {
            case "/api/v4/pipelines": return .http(404)
            case "/api/v4/projects":
                // EE was first in the old index; CE was tenth. The server
                // now reports both as active, and omits an older cached item.
                return .json(self.gitLabProjectListJSON([1, 10] + Array(2...9) + [11], activity: "2026-09-16T04:15:00.000Z"))
            case "/api/v4/projects/1/pipelines": return .json(self.gitLabPipelineJSON(project: 1, run: 5561))
            case "/api/v4/projects/10/pipelines": return .json(self.gitLabPipelineJSON(project: 10, run: 5560))
            case "/api/v4/projects/2/pipelines": return .hold
            default: return .json("[]")
            }
        }

        fixture.store.refreshCI()
        try await eventually {
            fixture.store.pipelineCache[cached[0].id]?.first?.id == "gitlab-5561" &&
            fixture.store.pipelineCache[cached[9].id]?.first?.id == "gitlab-5560" &&
            fixture.router.requests.contains { $0.url!.path == "/api/v4/projects/2/pipelines" }
        }
        XCTAssertTrue(fixture.store.isRefreshingCI, "CE and EE are visible while another request is still pending")
        XCTAssertTrue(Set(fixture.store.recentCIActivities.map(\.id)).isSuperset(of: [cached[0].id, cached[9].id]))
        XCTAssertNotNil(fixture.store.accessibleCIProjects.first { $0.id == cached[9].id }?.updatedAt)
        XCTAssertEqual(fixture.store.pipelineCache[cached[11].id]?.first?.id, "cached", "A partial activity list must retain older cached projects")
        let indexURL = try XCTUnwrap(fixture.router.requests.first { $0.url!.path == "/api/v4/projects" }?.url)
        let query = URLComponents(url: indexURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains { $0.name == "order_by" && $0.value == "last_activity_at" })
        XCTAssertTrue(query.contains { $0.name == "sort" && $0.value == "desc" })

        fixture.router.releaseHeld(host: "online.test", result: .failure(.timedOut))
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertFalse(fixture.router.requests.contains { $0.url!.path == "/api/v4/projects/3/pipelines" }, "Stop after the first network failure")
        let restored = StackHubStore(defaults: fixture.defaults)
        XCTAssertEqual(restored.pipelineCache[cached[9].id]?.first?.id, "gitlab-5560")
        let cursors = try JSONDecoder().decode([String: Date].self, from: XCTUnwrap(fixture.defaults.data(forKey: "stackhub.ci.gitlab-project-pipeline-sync-dates")))
        XCTAssertNotNil(cursors["\(online.id.uuidString):\(cached[9].id)"])
        XCTAssertNil(cursors["\(online.id.uuidString):\(cached[1].id)"])
    }

    @MainActor
    func testLegacyPollingRotatesBeyondFirstBatchEvenWhenAProjectDeniesAccess() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online])
        defer { fixture.cleanUp() }
        fixture.store.accessibleCIProjects = (1...26).map { cachedProject(online, number: $0) }
        fixture.router.respond { request in
            switch request.url!.path {
            case "/api/v4/pipelines": return .http(404)
            case "/api/v4/projects": return .json(self.gitLabProjectListJSON(Array(1...26)))
            case "/api/v4/projects/9/pipelines", "/api/v4/projects/9": return .http(403)
            default: return .json("[]")
            }
        }
        for _ in 0..<12 {
            let before = fixture.router.requests.count
            fixture.store.refreshCI()
            try await eventually { !fixture.store.isRefreshingCI }
            XCTAssertLessThanOrEqual(fixture.router.requests.dropFirst(before).filter {
                $0.url!.path.hasPrefix("/api/v4/projects/") && $0.url!.path.hasSuffix("/pipelines")
            }.count, 10)
        }
        let paths = Set(fixture.router.requests.map { $0.url!.path })
        for id in 1...26 {
            XCTAssertTrue(paths.contains("/api/v4/projects/\(id)/pipelines"), "Project \(id) must eventually be polled")
        }
        XCTAssertEqual(fixture.router.requests.filter { $0.url!.path == "/api/v4/projects" }.count, 12)
        XCTAssertTrue(fixture.store.ciError == nil || fixture.store.ciError!.contains("403"))
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
    func testInitialGitLabSyncBoundsIndexPipelinesAndStepRequests() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online])
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            let path = request.url!.path
            if path == "/api/v4/pipelines" { return .http(404) }
            if path == "/api/v4/projects" {
                return .json(self.gitLabProjectListJSON(Array(1...100), activity: "2026-09-16T04:15:00.000Z"))
            }
            if path.hasSuffix("/jobs") { return .json("[]") }
            if path.hasSuffix("/pipelines"), let id = Int(path.split(separator: "/")[3]) {
                return .json(self.gitLabPipelineJSON(project: id, run: id))
            }
            return .http(500)
        }
        for _ in 0..<7 {
            let before = fixture.router.requests.count
            fixture.store.refreshCI()
            try await eventually { !fixture.store.isRefreshingCI }
            let requests = Array(fixture.router.requests.dropFirst(before))
            XCTAssertEqual(requests.filter { $0.url!.path == "/api/v4/projects" }.count, 1)
            XCTAssertEqual(requests.filter { $0.url!.path.hasPrefix("/api/v4/projects/") && $0.url!.path.hasSuffix("/pipelines") }.count, 10)
            XCTAssertLessThanOrEqual(requests.filter { $0.url!.path.hasSuffix("/jobs") }.count, 4)
            XCTAssertLessThanOrEqual(fixture.store.recentCIActivities.count, 20)
            XCTAssertEqual(fixture.store.accessibleCIProjects.count, 30)
            XCTAssertNil(fixture.store.ciError)
        }
        XCTAssertEqual(fixture.store.recentCIActivities.count, 20)
        XCTAssertGreaterThan(fixture.store.pipelineCache.count, 20, "Display limits do not erase cached history")
        let index = try XCTUnwrap(fixture.router.requests.first { $0.url!.path == "/api/v4/projects" }?.url)
        XCTAssertTrue(URLComponents(url: index, resolvingAgainstBaseURL: false)!.queryItems!.contains {
            $0.name == "per_page" && $0.value == "30"
        })
    }

    @MainActor
    func testGlobalFeedBoundsMetadataAndRunningChecksWithoutLosingDeferredProjects() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online])
        defer { fixture.cleanUp() }
        let feed = "[" + (1...20).map {
            String(gitLabPipelineJSON(project: $0, run: $0).dropFirst().dropLast())
        }.joined(separator: ",") + "]"
        fixture.router.respond { request in
            let path = request.url!.path
            if path == "/api/v4/pipelines" { return .json(feed) }
            if path.hasSuffix("/jobs") { return .json("[]") }
            let parts = path.split(separator: "/")
            guard parts.count >= 4, let id = Int(parts[3]) else { return .http(500) }
            if parts.count == 4 {
                return .json(String(self.gitLabProjectListJSON([id]).dropFirst().dropLast()))
            }
            return .json(String(self.gitLabPipelineJSON(project: id, run: id).dropFirst().dropLast()))
        }
        for cycle in 0..<3 {
            let before = fixture.router.requests.count
            fixture.store.refreshCI()
            try await eventually { !fixture.store.isRefreshingCI }
            let requests = Array(fixture.router.requests.dropFirst(before))
            XCTAssertLessThanOrEqual(requests.filter { $0.url!.path.split(separator: "/").count == 4 }.count, 10)
            XCTAssertLessThanOrEqual(requests.filter { $0.url!.path.split(separator: "/").count == 6 }.count, 10)
            XCTAssertLessThanOrEqual(requests.filter { $0.url!.path.hasSuffix("/jobs") }.count, 4)
            XCTAssertLessThanOrEqual(fixture.store.recentCIActivities.count, 20)
            XCTAssertNil(fixture.store.ciError)
            let cursors = try JSONDecoder().decode([String: Date].self, from: XCTUnwrap(fixture.defaults.data(forKey: "stackhub.ci.gitlab-pipeline-sync-dates")))
            if cycle < 1 { XCTAssertNil(cursors[online.id.uuidString], "Do not skip metadata left for a later cycle") }
            else { XCTAssertNotNil(cursors[online.id.uuidString]) }
        }
        XCTAssertEqual(fixture.store.pipelineCache.count, 20)
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
    func testGitHubFullAndIncrementalRefreshStayWithinFiveRepositories() async throws {
        let fixture = makeFixture(instances: [], githubToken: "test-token")
        defer { fixture.cleanUp() }
        for cycle in 0..<3 {
            let firstID = cycle == 0 ? 1 : 21
            let repositories = cycle == 2 ? "[]" : "[" + (firstID..<(firstID + 20)).map { id in
                """
                {"name":"repo\(id)","full_name":"owner/repo\(id)","default_branch":"main","updated_at":"2026-09-\(cycle == 0 ? "15" : "16")T10:00:00Z"}
                """
            }.joined(separator: ",") + "]"
            fixture.router.respond { request in
                if request.url!.path == "/user/repos" { return .json(repositories) }
                if request.url!.path.hasSuffix("/actions/runs") { return .json("{\"workflow_runs\":[]}") }
                return .http(500)
            }
            let before = fixture.router.requests.count
            fixture.store.refreshCI()
            try await eventually { !fixture.store.isRefreshingCI }
            let requests = Array(fixture.router.requests.dropFirst(before))
            let indexes = requests.filter { $0.url!.path == "/user/repos" }
            XCTAssertEqual(indexes.count, 1)
            let index = try XCTUnwrap(indexes.first?.url)
            let query = URLComponents(url: index, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains { $0.name == "per_page" && $0.value == "5" })
            XCTAssertEqual(query.contains { $0.name == "since" }, cycle != 0)
            let runs = requests.filter { $0.url!.path.hasSuffix("/actions/runs") }
            XCTAssertEqual(runs.count, 5)
            XCTAssertEqual(Set(runs.map { $0.url!.path }), Set((firstID..<(firstID + 5)).map {
                "/repos/owner/repo\($0)/actions/runs"
            }))
            XCTAssertEqual(fixture.store.accessibleCIProjects.count, 5)
            XCTAssertNil(fixture.store.ciError)
        }
    }

    @MainActor
    func testRefreshTicksAndManualClicksDoNotOverlapPendingDetailLoads() async throws {
        let office = instance("office")
        var now = Date()
        let scheduler = CIRefreshScheduler(now: { now })
        let fixture = makeFixture(instances: [office], scheduler: scheduler, githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.path.hasSuffix("/jobs") { return .hold }
            if request.url!.host == "office.test" { return .json(self.pipelineJSON()) }
            if request.url!.path == "/user/repos" { return .json(self.githubRepositoryJSON) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "success"))
        }
        fixture.store.refreshCIIfNeeded()
        try await eventually { fixture.router.requests.filter { $0.url!.path.hasSuffix("/jobs") }.count == 2 }
        let before = fixture.router.requests.count
        for _ in 0..<3 {
            now.addTimeInterval(60)
            fixture.store.refreshCIIfNeeded()
            fixture.store.refreshCI()
            fixture.store.refreshCI(forceProjectDiscovery: true)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fixture.router.requests.count, before, "Skip both manual and automatic refreshes until details finish")
        XCTAssertTrue(scheduler.isRefreshing(.github))
        XCTAssertTrue(scheduler.isRefreshing(.gitlab(office.id)))

        fixture.router.respond { request in
            if request.url!.host == "office.test" { return .hold }
            if request.url!.path == "/user/repos" { return .json("[]") }
            if request.url!.path.hasSuffix("/jobs") { return .json(self.githubJobsJSON()) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "success"))
        }
        fixture.router.releaseHeld(host: "api.github.com", result: .json(githubJobsJSON()))
        try await eventually { !scheduler.isRefreshing(.github) }
        fixture.store.refreshCIIfNeeded()
        XCTAssertEqual(fixture.router.requests.count, before, "Skipped refreshes must not queue behind the current round")

        now.addTimeInterval(31)
        fixture.store.refreshCIIfNeeded()
        try await eventually {
            fixture.router.requests.count > before && !scheduler.isRefreshing(.github)
        }
        XCTAssertEqual(fixture.router.count(host: "office.test"), 2, "A finished source can refresh while another is still waiting")
        fixture.router.releaseHeld(host: "office.test", result: .json("[]"))
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.router.count(host: "api.github.com"), 5)
        XCTAssertNil(fixture.store.ciError)
    }

    @MainActor
    func testGitHubCompletionRefreshesWithoutRepositoryChangeAndLateJobsCannotRestoreRunning() async throws {
        let fixture = makeFixture(instances: [], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json(self.githubRepositoryJSON) }
            if request.url!.path.hasSuffix("/jobs") { return .json("{\"jobs\":[]}") }
            return .json(self.githubRunsJSON(status: "in_progress", conclusion: nil))
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        let projectID = "github:owner/example"
        let running = try XCTUnwrap(fixture.store.pipelineCache[projectID]?.first)
        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.running, 1)

        fixture.router.respond { request in
            switch request.url!.path {
            case "/user/repos": return .json("[]")
            case "/repos/owner/example/actions/runs": return .json(self.githubRunsJSON(status: "completed", conclusion: "success"))
            default: return .hold
            }
        }
        fixture.store.openPipeline(running)
        try await eventually { fixture.router.requests.filter { $0.url!.path.hasSuffix("/jobs") }.count == 2 }
        fixture.store.refreshCI()
        try await eventually {
            fixture.store.pipelineCache[projectID]?.first?.state == .success &&
            fixture.router.requests.filter { $0.url!.path.hasSuffix("/jobs") }.count == 3
        }
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.state, .success)
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.running, 0)
        XCTAssertEqual(fixture.store.selectedPipeline?.state, .success)
        XCTAssertNotEqual(fixture.store.pipelineCache[projectID]?.first?.duration, running.duration)
        XCTAssertTrue(fixture.router.requests.contains {
            $0.url!.path == "/user/repos" && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "since" } == true
        }, "Completion must refresh on the incremental path as well")

        fixture.router.releaseHeld(host: "api.github.com", result: .json("""
        {"jobs":[{"id":1,"name":"Build","status":"completed","conclusion":"success"}]}
        """))
        try await eventually { fixture.store.pipelineCache[projectID]?.first?.hasLoadedStages == true }
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.state, .success)
        XCTAssertEqual(fixture.store.selectedPipeline?.state, .success)
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.running, 0)
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.stages.first?.state, .success)
    }

    @MainActor
    func testGitHubRerunIsDiscoveredWithoutRepositoryChange() async throws {
        let fixture = makeFixture(instances: [], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json(self.githubRepositoryJSON) }
            if request.url!.path.hasSuffix("/jobs") { return .json(self.githubJobsJSON()) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "success"))
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.running, 0)

        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json("[]") }
            if request.url!.path.hasSuffix("/jobs") { return .json("{\"jobs\":[]}") }
            return .json(self.githubRunsJSON(status: "in_progress", conclusion: nil))
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.pipelineCache["github:owner/example"]?.first?.state, .running)
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.running, 1)
        XCTAssertNil(fixture.store.ciError)
    }

    @MainActor
    func testGitHubFailedConclusionReplacesRunningAndUpdatesMenuCount() async throws {
        let fixture = makeFixture(instances: [], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json(self.githubRepositoryJSON) }
            if request.url!.path.hasSuffix("/jobs") { return .json("{\"jobs\":[]}") }
            return .json(self.githubRunsJSON(status: "in_progress", conclusion: nil))
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json("[]") }
            if request.url!.path.hasSuffix("/jobs") { return .json(self.githubJobsJSON(conclusion: "failure")) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "failure"))
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.pipelineCache["github:owner/example"]?.first?.state, .failed)
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.running, 0)
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.unreadFailures, 1)
        XCTAssertNil(fixture.store.ciError)
    }

    @MainActor
    func testGitHubAutomaticallyLoadsCompletedDetailsAndReusesFinalCache() async throws {
        let fixture = makeFixture(instances: [], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json(self.githubRepositoryJSON) }
            if request.url!.path.hasSuffix("/jobs") { return .json(self.githubJobsJSON()) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "success"))
        }
        fixture.store.refreshCIIfNeeded()
        try await eventually { !fixture.store.isRefreshingCI }
        let pipeline = try XCTUnwrap(fixture.store.pipelineCache["github:owner/example"]?.first)
        XCTAssertEqual(pipeline.state, .success)
        XCTAssertTrue(pipeline.hasLoadedStages, "No click on View should be necessary")
        XCTAssertEqual(pipeline.stages.first?.name, "Build")
        XCTAssertEqual(pipeline.stageSnapshotState, .success)
        let requests = fixture.router.requests.filter { $0.url!.path.hasSuffix("/jobs") }.count
        XCTAssertEqual(requests, 1)

        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.router.requests.filter { $0.url!.path.hasSuffix("/jobs") }.count, requests)
        XCTAssertFalse(fixture.router.requests.contains { $0.url!.path.contains("/logs") })
    }

    @MainActor
    func testGitHubRetriesMissingCompletedDetailsAfterTimeoutWithoutRepositoryChanges() async throws {
        var now = Date()
        let fixture = makeFixture(instances: [], scheduler: CIRefreshScheduler(now: { now }), githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json(self.githubRepositoryJSON) }
            if request.url!.path.hasSuffix("/jobs") { return .failure(.timedOut) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "failure"))
        }
        fixture.store.refreshCIIfNeeded()
        try await eventually { !fixture.store.isRefreshingCI }
        let projectID = "github:owner/example"
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.state, .failed)
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.hasLoadedStages, false)
        XCTAssertTrue(fixture.store.ciError?.contains("GitHub") == true)

        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json("[]") }
            if request.url!.path.hasSuffix("/jobs") { return .json(self.githubJobsJSON(conclusion: "failure")) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "failure"))
        }
        now.addTimeInterval(61)
        fixture.store.refreshCIIfNeeded()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.hasLoadedStages, true)
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.stages.first?.state, .failed)
        XCTAssertEqual(fixture.router.requests.filter { $0.url!.path.hasSuffix("/jobs") }.count, 2)
        XCTAssertNil(fixture.store.ciError)
        let reloaded = StackHubStore(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.pipelineCache[projectID]?.first?.stageSnapshotState, .failed)
    }

    @MainActor
    func testGitHubPublishesSummaryAndOtherInstancesWhileJobsAreWaiting() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.host == "online.test" {
                return .json(request.url!.path.hasSuffix("/jobs") ? "[]" : self.pipelineJSON())
            }
            if request.url!.path == "/user/repos" { return .json(self.githubRepositoryJSON) }
            if request.url!.path.hasSuffix("/jobs") { return .hold }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "success"))
        }
        fixture.store.refreshCIIfNeeded()
        let projectID = "github:owner/example"
        try await eventually {
            fixture.store.pipelineCache[projectID]?.first?.state == .success &&
            fixture.store.pipelineCache["gitlab:\(online.id.uuidString):1"]?.first?.state == .success &&
            fixture.router.requests.contains { $0.url!.host == "api.github.com" && $0.url!.path.hasSuffix("/jobs") }
        }
        XCTAssertTrue(fixture.store.isRefreshingCI)
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.hasLoadedStages, false)
        fixture.router.releaseHeld(host: "api.github.com", result: .json(githubJobsJSON()))
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.hasLoadedStages, true)
    }

    @MainActor
    func testGitHubRefreshesFinalJobsEvenWhenRunningSnapshotAlreadyHadDetails() async throws {
        let fixture = makeFixture(instances: [], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json(self.githubRepositoryJSON) }
            // A job can complete before the overall workflow does.
            if request.url!.path.hasSuffix("/jobs") { return .json(self.githubJobsJSON()) }
            return .json(self.githubRunsJSON(status: "in_progress", conclusion: nil))
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        let projectID = "github:owner/example"
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.stageSnapshotState, .running)
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json("[]") }
            if request.url!.path.hasSuffix("/jobs") { return .json(self.githubJobsJSON()) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "success"))
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.router.requests.filter { $0.url!.path.hasSuffix("/jobs") }.count, 2)
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.stageSnapshotState, .success)
    }

    @MainActor
    func testGitLabRetriesMissingCompletedJobsAfterTheyLeaveTheIncrementalFeed() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online])
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            request.url!.path.hasSuffix("/jobs") ? .http(403) : .json(self.pipelineJSON())
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        let projectID = "gitlab:\(online.id.uuidString):1"
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.hasLoadedStages, false)
        fixture.router.respond { request in
            if request.url!.path.hasSuffix("/jobs") {
                return .json("[{\"id\":1,\"name\":\"Build\",\"stage\":\"build\",\"status\":\"success\",\"duration\":2}]")
            }
            return .json("[]")
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.pipelineCache[projectID]?.first?.hasLoadedStages, true)
        XCTAssertEqual(fixture.router.requests.filter { $0.url!.path.hasSuffix("/jobs") }.count, 2)
    }

    @MainActor
    func testFailureArrivingAfterPanelOpensIsReadButNextBackgroundFailureRemainsUnread() async throws {
        let fixture = makeFixture(instances: [], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .hold }
            if request.url!.path.hasSuffix("/jobs") { return .json(self.githubJobsJSON(conclusion: "failure")) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "failure"))
        }
        fixture.store.refreshCI()
        try await eventually { fixture.router.count(host: "api.github.com") == 1 }
        fixture.store.setPanelVisible(true)
        fixture.store.setCIActivityVisible(true)
        fixture.router.releaseHeld(host: "api.github.com", result: .json(githubRepositoryJSON))
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.recentCIActivities.first?.pipeline.state, .failed)
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.unreadFailures, 0)
        XCTAssertEqual(StackHubStore(defaults: fixture.defaults).menuBarPipelineStatus.unreadFailures, 0)

        fixture.store.setPanelVisible(false)
        fixture.router.respond { request in
            if request.url!.path == "/user/repos" { return .json("[]") }
            if request.url!.path.hasSuffix("/jobs") { return .json(self.githubJobsJSON(conclusion: "failure")) }
            return .json(self.githubRunsJSON(status: "completed", conclusion: "failure", runID: 2))
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.store.recentCIActivities.first?.pipeline.id, "github-2")
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.unreadFailures, 1)
        fixture.store.setPanelVisible(true)
        XCTAssertEqual(fixture.store.menuBarPipelineStatus.unreadFailures, 0)
    }

    @MainActor
    func testDisabledGitLabCIIsConfirmedCachedSkippedAndRecheckedWhenReenabled() async throws {
        let online = instance("online")
        var now = Date()
        let fixture = makeFixture(instances: [online], scheduler: CIRefreshScheduler(now: { now }))
        defer { fixture.cleanUp() }
        let project = cachedProject(online, number: 1)
        fixture.store.accessibleCIProjects = [project]
        fixture.store.pipelineCache[project.id] = [cachedPipeline(project)]
        fixture.router.respond { request in
            switch request.url!.path {
            case "/api/v4/pipelines": return .http(404)
            case "/api/v4/projects": return .json("[]")
            case "/api/v4/projects/1/pipelines": return .http(403)
            case "/api/v4/projects/1": return .json(self.gitLabProjectJSON(ciEnabled: false))
            default: return .http(500)
            }
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertNil(fixture.store.ciError)
        XCTAssertEqual(fixture.store.accessibleCIProjects.first?.isCIEnabled, false)
        XCTAssertEqual(fixture.store.pipelineCache[project.id]?.first?.id, "cached")
        XCTAssertEqual(StackHubStore(defaults: fixture.defaults).accessibleCIProjects.first?.isCIEnabled, false)
        let requestCount = fixture.router.requests.count

        now.addTimeInterval(31)
        fixture.store.refreshCIIfNeeded()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertEqual(fixture.router.requests.count, requestCount + 1, "Refresh the activity index but skip known disabled pipelines and jobs")

        fixture.router.respond { request in
            if request.url!.path == "/api/v4/projects" { return .json("[]") }
            if request.url!.path == "/api/v4/projects/1" { return .json(self.gitLabProjectJSON(ciEnabled: true)) }
            return .json(request.url!.path.hasSuffix("/jobs") ? "[]" : self.pipelineJSON())
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertNil(fixture.store.ciError)
        XCTAssertEqual(fixture.store.accessibleCIProjects.first?.isCIEnabled, true)
        XCTAssertEqual(fixture.store.pipelineCache[project.id]?.first?.id, "gitlab-1")
    }

    @MainActor
    func testGitLabDiscoverySkipsDisabledCIWithoutTryingItsPipelines() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online])
        defer { fixture.cleanUp() }
        fixture.router.respond { request in
            if request.url!.path == "/api/v4/pipelines" { return .http(404) }
            if request.url!.path == "/api/v4/projects" { return .json("[\(self.gitLabProjectJSON(ciEnabled: false))]") }
            return .http(500)
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertNil(fixture.store.ciError)
        XCTAssertEqual(fixture.store.accessibleCIProjects.first?.isCIEnabled, false)
        XCTAssertEqual(fixture.router.requests.count, 2)
    }

    @MainActor
    func testGitLabPermissionFailureIsNotMistakenForDisabledCI() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online])
        defer { fixture.cleanUp() }
        fixture.store.accessibleCIProjects = [cachedProject(online, number: 1)]
        fixture.router.respond { request in
            if request.url!.path == "/api/v4/pipelines" { return .http(404) }
            if request.url!.path == "/api/v4/projects" { return .json("[]") }
            if request.url!.path == "/api/v4/projects/1" { return .json(self.gitLabProjectJSON(ciEnabled: true)) }
            return .http(403)
        }
        fixture.store.refreshCI()
        try await eventually { !fixture.store.isRefreshingCI }
        XCTAssertTrue(fixture.store.ciError?.contains("403") == true)
        XCTAssertEqual(fixture.store.accessibleCIProjects.first?.isCIEnabled, true)
    }

    @MainActor
    func testConnectionChecksPublishIndependentlyAndDoNotTrustSavedCredentials() async throws {
        let office = instance("office")
        let online = instance("online")
        let fixture = makeFixture(instances: [office, online], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.defaults.set(try JSONEncoder().encode([office, online]), forKey: "stackhub.gitlab.instances")
        fixture.defaults.set(true, forKey: "stackhub.github.connected")
        let restored = StackHubStore(defaults: fixture.defaults)
        XCTAssertEqual(restored.connectionStatus(for: .github).state, .unchecked)
        XCTAssertEqual(restored.connectionStatus(for: .gitlab(online.id)).state, .unchecked)
        XCTAssertNotEqual(fixture.store.connectionStatus(for: .gitlab(online.id)).state, .connected)
        fixture.router.respond { request in
            request.url!.host == "office.test" ? .hold : .json("{\"id\":1}")
        }
        fixture.store.checkCIConnections()
        try await eventually {
            fixture.store.connectionStatus(for: .github).state == .connected &&
            fixture.store.connectionStatus(for: .gitlab(online.id)).state == .connected &&
            fixture.router.count(host: "office.test") == 1
        }
        XCTAssertEqual(fixture.store.connectionStatus(for: .gitlab(office.id)).state, .checking)
        fixture.store.checkCIConnection(.gitlab(office.id))
        fixture.router.releaseHeld(host: "office.test", result: .failure(.timedOut))
        try await eventually { fixture.store.connectionStatus(for: .gitlab(office.id)).state == .unreachable }
        XCTAssertEqual(fixture.router.count(host: "office.test"), 1)
        XCTAssertTrue(fixture.router.requests.allSatisfy { $0.timeoutInterval == 3 && $0.cachePolicy == .reloadIgnoringLocalCacheData })
        XCTAssertEqual(Set(fixture.router.requests.compactMap { $0.url?.path }), ["/user", "/api/v4/user"])
        XCTAssertNil(fixture.store.ciError, "Connection checks must not overwrite pipeline sync results")
        XCTAssertNotNil(fixture.store.connectionStatus(for: .github).duration)
    }

    @MainActor
    func testConnectionChecksDistinguishAuthenticationPermissionAndRecovery() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online], githubToken: "test-token")
        defer { fixture.cleanUp() }
        fixture.router.respond { request in request.url!.host == "api.github.com" ? .http(401) : .http(403) }
        fixture.store.checkCIConnections()
        try await eventually {
            fixture.store.connectionStatus(for: .github).state == .unauthorized &&
            fixture.store.connectionStatus(for: .gitlab(online.id)).state == .forbidden
        }
        fixture.router.respond { _ in .json("{\"id\":1}") }
        fixture.store.checkCIConnections()
        try await eventually {
            fixture.store.connectionStatus(for: .github).state == .connected &&
            fixture.store.connectionStatus(for: .gitlab(online.id)).state == .connected
        }
        XCTAssertNil(fixture.store.connectionStatus(for: .github).detail)

        fixture.router.respond { _ in .json("{}") }
        fixture.store.checkCIConnection(.github)
        try await eventually { fixture.store.connectionStatus(for: .github).state == .failed }
    }

    @MainActor
    func testConnectionChecksOnlyPollVisibleManagementPageAndRejectStaleResponses() async throws {
        let online = instance("online")
        let fixture = makeFixture(instances: [online])
        defer { fixture.cleanUp() }
        fixture.router.respond { _ in .hold }
        fixture.store.setCIConnectionsVisible(true)
        XCTAssertTrue(fixture.router.requests.isEmpty)
        fixture.store.setPanelVisible(true)
        try await eventually { fixture.router.count(host: "online.test") == 1 }
        fixture.store.invalidateCIConnectionCheck(.gitlab(online.id))
        fixture.router.respond { _ in .http(401) }
        fixture.store.checkCIConnection(.gitlab(online.id))
        try await eventually { fixture.store.connectionStatus(for: .gitlab(online.id)).state == .unauthorized }
        fixture.router.releaseHeld(host: "online.test", result: .json("{\"id\":1}"))
        XCTAssertEqual(fixture.store.connectionStatus(for: .gitlab(online.id)).state, .unauthorized)

        fixture.store.setPanelVisible(false)
        let count = fixture.router.requests.count
        fixture.store.checkCIConnectionsIfVisible()
        XCTAssertEqual(fixture.router.requests.count, count)
        fixture.router.respond { _ in .json("{\"id\":1}") }
        fixture.store.setPanelVisible(true)
        try await eventually { fixture.store.connectionStatus(for: .gitlab(online.id)).state == .connected }
        XCTAssertEqual(fixture.store.connectionStatus(for: .github).state, .unconfigured)
    }

    private func gitLabProjectJSON(ciEnabled: Bool) -> String {
        "{\"id\":1,\"name\":\"Example\",\"path_with_namespace\":\"team/example\",\"default_branch\":\"main\",\"builds_access_level\":\"\(ciEnabled ? "enabled" : "disabled")\",\"jobs_enabled\":\(ciEnabled)}"
    }

    private func githubJobsJSON(conclusion: String = "success") -> String {
        "{\"jobs\":[{\"id\":1,\"name\":\"Build\",\"status\":\"completed\",\"conclusion\":\"\(conclusion)\"}]}"
    }

    private var githubRepositoryJSON: String {
        """
        [{"name":"example","full_name":"owner/example","default_branch":"main","updated_at":"2026-09-15T10:00:00Z"}]
        """
    }

    private func githubRunsJSON(status: String, conclusion: String?, runID: Int = 1) -> String {
        let result = conclusion.map { "\"\($0)\"" } ?? "null"
        let updatedAt = conclusion == nil ? "2026-09-15T10:00:00Z" : "2026-09-15T10:02:00Z"
        return """
        {"workflow_runs":[{"id":\(runID),"status":"\(status)","conclusion":\(result),"head_branch":"main","head_sha":"abcdef123","updated_at":"\(updatedAt)","run_started_at":"2026-09-15T10:00:00Z"}]}
        """
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

    private func gitLabProjectListJSON(_ ids: [Int], activity: String? = nil) -> String {
        "[" + ids.map { id in
            let timestamp = activity.map { ",\"last_activity_at\":\"\($0)\"" } ?? ""
            return "{\"id\":\(id),\"name\":\"Project \(id)\",\"path_with_namespace\":\"team/project\(id)\",\"default_branch\":\"main\"\(timestamp)}"
        }.joined(separator: ",") + "]"
    }

    private func gitLabPipelineJSON(project: Int, run: Int) -> String {
        "[{\"id\":\(run),\"project_id\":\(project),\"status\":\"running\",\"ref\":\"v0.39.0\",\"sha\":\"abcdef123\",\"updated_at\":\"2026-09-16T04:15:05.882Z\"}]"
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
