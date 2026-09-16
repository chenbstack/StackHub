import Foundation
import XCTest
@testable import StackHub

final class CIActivityOrderingTests: XCTestCase {
    func testGitLabUrgentProjectsShareHardLimitAndKeepPriority() {
        let projects = (1...30).map { project("gitlab:one:\($0)", provider: "GitLab CI", timestamp: 200) }
        var successes = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, Date(timeIntervalSince1970: 300)) })
        // More than eight repositories changed since their previous poll.
        for repository in projects[8..<20] { successes[repository.id] = Date(timeIntervalSince1970: 100) }
        let running = projects[28]
        let result = CIActivityOrdering.gitLabProjectsRequiringPipelineRefresh(
            projects: projects,
            pipelineCache: [running.id: [pipeline("run", project: running, timestamp: 300, state: .running)]],
            followedIDs: [projects[29].id], successfulPolls: successes, attemptedPolls: [:], batchSize: 8
        )
        let ids = Set(result.map(\.id))
        XCTAssertEqual(result.count, 8, "Urgent work must not expand the batch")
        XCTAssertTrue(ids.contains(running.id))
        XCTAssertTrue(ids.contains(projects[29].id))
        XCTAssertEqual(result.count, ids.count, "Each project is only requested once per cycle")
    }

    func testBusyGitLabProjectsCannotStarveBackgroundProjects() {
        let projects = (1...100).map { project("gitlab:one:\($0)", provider: "GitLab CI", timestamp: 200) }
        let followed = Set(projects.prefix(30).map(\.id))
        var attempts: [String: Date] = [:]
        var successes: [String: Date] = [:]
        var visited = Set<String>()
        for cycle in 0..<50 {
            let batch = CIActivityOrdering.gitLabProjectsRequiringPipelineRefresh(
                projects: projects, pipelineCache: [:], followedIDs: followed,
                successfulPolls: successes, attemptedPolls: attempts, batchSize: 8
            )
            XCTAssertLessThanOrEqual(batch.count, 8)
            XCTAssertEqual(batch.count, Set(batch.map(\.id)).count)
            for repository in batch {
                attempts[repository.id] = Date(timeIntervalSince1970: Double(300 + cycle))
                // Some failed requests never advance their successful cursor.
                if repository.id != projects[0].id { successes[repository.id] = attempts[repository.id] }
                visited.insert(repository.id)
            }
        }
        XCTAssertEqual(visited, Set(projects.map(\.id)))
    }

    func testActivityListKeepsOnlyTwentyLatestProjectsWithoutDiscardingCachedHistory() {
        let projects = (1...100).map { project("gitlab:one:\($0)", provider: "GitLab CI") }
        let cache = Dictionary(uniqueKeysWithValues: projects.enumerated().map { index, repository in
            (repository.id, [pipeline("run-\(index)", project: repository, timestamp: Double(index))])
        })
        let result = CIActivityOrdering.latestActivities(projects: projects, pipelineCache: cache)
        XCTAssertEqual(result.map(\.id), projects.suffix(20).reversed().map(\.id))
        XCTAssertEqual(cache.count, 100)
    }

    func testExecutionDurationFormattingIsCompactAndProviderIndependent() {
        withAppLanguage(.simplifiedChinese) {
        XCTAssertEqual(CIExecutionTimeFormatter.duration(seconds: 0), "0 秒")
        XCTAssertEqual(CIExecutionTimeFormatter.duration(seconds: 125.4), "2 分 5 秒")
        XCTAssertEqual(CIExecutionTimeFormatter.duration(seconds: 3660), "1 小时 1 分钟")
        XCTAssertEqual(CIExecutionTimeFormatter.duration(seconds: nil), "—")
        }
    }

    func testExecutionDurationCanBeDerivedFromRunDates() {
        withAppLanguage(.simplifiedChinese) {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 218)

        XCTAssertEqual(CIExecutionTimeFormatter.duration(from: start, to: end), "1 分 58 秒")
        XCTAssertEqual(CIExecutionTimeFormatter.duration(from: start, to: nil), "—")
        }
    }

    func testEnglishLocalizationUsesBundledResources() {
        withAppLanguage(.english) {
            XCTAssertEqual(L("项目"), "Projects")
            XCTAssertEqual(CIExecutionTimeFormatter.duration(seconds: 125.4), "2 min 5 sec")
            XCTAssertEqual(ServiceStatus.warning.label, "Warning")
        }
    }

    func testLanguageCanSwitchBackToChineseAfterLoadingEnglishResources() {
        withAppLanguage(.english) {
            XCTAssertEqual(CIExecutionTimeFormatter.duration(seconds: 125.4), "2 min 5 sec")
        }
        withAppLanguage(.simplifiedChinese) {
            XCTAssertEqual(L("项目"), "项目")
            XCTAssertEqual(CIExecutionTimeFormatter.duration(seconds: 125.4), "2 分 5 秒")
        }
    }

    private func withAppLanguage(_ language: AppLanguage, perform body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: AppLanguage.storageKey)
        defaults.set(language.rawValue, forKey: AppLanguage.storageKey)
        defer {
            if let previous {
                defaults.set(previous, forKey: AppLanguage.storageKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.storageKey)
            }
        }
        body()
    }

    func testMergesPlatformsByPipelineTimeRatherThanProjectOrder() {
        let weekOldGitLab = project("gitlab:one:1", provider: "GitLab CI")
        let monthOldGitHub = project("github:owner/old")
        let recentGitLab = project("gitlab:two:2", provider: "GitLab CI")
        let newestGitHub = project("github:owner/new")
        let projects = [weekOldGitLab, monthOldGitHub, recentGitLab, newestGitHub]
        let cache = [
            weekOldGitLab.id: [pipeline("gl-week", project: weekOldGitLab, timestamp: 200)],
            monthOldGitHub.id: [pipeline("gh-month", project: monthOldGitHub, timestamp: 100)],
            recentGitLab.id: [pipeline("gl-day", project: recentGitLab, timestamp: 300)],
            newestGitHub.id: [pipeline("gh-hour", project: newestGitHub, timestamp: 400)]
        ]
        let expected = [newestGitHub.id, recentGitLab.id, weekOldGitLab.id, monthOldGitHub.id]

        XCTAssertEqual(CIActivityOrdering.latestActivities(projects: projects, pipelineCache: cache).map(\.id), expected)
        XCTAssertEqual(CIActivityOrdering.latestActivities(projects: projects.reversed(), pipelineCache: cache).map(\.id), expected)
    }

    func testChoosesNewestRunFromUnsortedResponse() {
        let repository = project("github:owner/project")
        let runs = [
            pipeline("old", project: repository, timestamp: 100),
            pipeline("unknown", project: repository, timestamp: nil),
            pipeline("new", project: repository, timestamp: 300),
            pipeline("middle", project: repository, timestamp: 200)
        ]
        let activities = CIActivityOrdering.latestActivities(projects: [repository], pipelineCache: [repository.id: runs])

        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.pipeline.id, "new")
        XCTAssertEqual(runs.sorted(by: CIActivityOrdering.newestFirst).map(\.id), ["new", "middle", "old", "unknown"])
    }

    func testMissingTimesSortLastAndTiesAreStable() {
        let projects = [project("d"), project("b"), project("c"), project("a")]
        let cache = Dictionary(uniqueKeysWithValues: projects.map { repository in
            (repository.id, [pipeline("run", project: repository, timestamp: ["a", "b"].contains(repository.id) ? 100 : nil)])
        })

        XCTAssertEqual(CIActivityOrdering.latestActivities(projects: projects, pipelineCache: cache).map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(CIActivityOrdering.latestActivities(projects: projects.reversed(), pipelineCache: cache).map(\.id), ["a", "b", "c", "d"])
    }

    func testProjectsWithoutPipelinesDoNotProduceActivityCards() {
        let empty = project("empty")
        let absent = project("absent")
        let active = project("active")
        let activities = CIActivityOrdering.latestActivities(
            projects: [empty, absent, active],
            pipelineCache: [empty.id: [], active.id: [pipeline("run", project: active, timestamp: 100)]]
        )

        XCTAssertEqual(activities.map(\.id), [active.id])
    }

    func testIndexDeduplicationPreservesRecentRepositoryOrder() {
        let newest = project("newest")
        let older = project("older")
        var duplicate = newest
        duplicate.name = "duplicate metadata"

        let projects = CIActivityOrdering.uniqueProjects([newest, older, duplicate])

        XCTAssertEqual(projects.map(\.id), [newest.id, older.id])
        XCTAssertEqual(projects.first?.name, newest.name)
    }

    func testIncrementalGitHubMergeRetainsOnlyBoundedRepositoryScope() {
        let cachedOld = project("github:owner/old", timestamp: 100)
        let cachedChanged = project("github:owner/changed", timestamp: 200)
        let changed = project("github:owner/changed", name: "Changed metadata", timestamp: 400)
        let newlyRecent = project("github:owner/new", timestamp: 500)

        let retained = CIActivityOrdering.mergedRecentProjects(
            changed: [changed, newlyRecent],
            cached: [cachedChanged, cachedOld],
            limit: 2
        )
        let refresh = CIActivityOrdering.projectsRequiringPipelineRefresh(
            retained: retained, pipelineCache: [:]
        )

        XCTAssertEqual(retained.map(\.id), [newlyRecent.id, changed.id])
        XCTAssertEqual(retained.last?.name, "Changed metadata")
        XCTAssertEqual(refresh.map(\.id), [newlyRecent.id, changed.id])
    }

    func testActionsPollIncludesUnchangedRepositoriesAndPrioritizesRunningOnes() {
        let idle = project("github:owner/idle")
        let active = project("github:owner/active")
        let running = Pipeline(id: "github-1", projectID: active.id, provider: active.provider,
                               repository: active.repository, branch: "main", commit: "", duration: "0 sec",
                               state: .running, stages: [], updatedAt: nil, webURL: nil)
        let refresh = CIActivityOrdering.projectsRequiringPipelineRefresh(
            retained: [idle, active, idle], pipelineCache: [active.id: [running]]
        )
        XCTAssertEqual(refresh.map(\.id), [active.id, idle.id])
    }

    func testSamePipelineIDFromDifferentGitLabInstancesDoesNotMergeCards() {
        let first = project("gitlab:first:1", provider: "GitLab CI")
        let second = project("gitlab:second:1", provider: "GitLab CI")
        let activities = CIActivityOrdering.latestActivities(
            projects: [first, first, second],
            pipelineCache: [
                first.id: [pipeline("gitlab-42", project: first, timestamp: 100)],
                second.id: [pipeline("gitlab-42", project: second, timestamp: 200)]
            ]
        )

        XCTAssertEqual(activities.map(\.id), [second.id, first.id])
    }

    func testRefreshMergesSummaryWithPreviouslyLoadedStagesAndLogs() {
        let repository = project("gitlab:one:1", provider: "GitLab CI")
        let stage = PipelineStage(id: "job-1", name: "build · compile", duration: "2 秒", state: .success, log: "cached log")
        let detailed = Pipeline(
            id: "gitlab-42", projectID: repository.id, provider: repository.provider, repository: repository.repository,
            branch: "main", commit: "old", duration: "2 秒", state: .success, stages: [stage], updatedAt: Date(timeIntervalSince1970: 100), webURL: nil,
            hasLoadedStages: true
        )
        let refreshed = pipeline("gitlab-42", project: repository, timestamp: 200)
        let merged = CIPipelineCache.merging(refreshed, with: detailed)

        XCTAssertTrue(merged.hasLoadedStages)
        XCTAssertEqual(merged.stages.map(\.id), ["job-1"])
        XCTAssertEqual(merged.stages.first?.log, "cached log")
        XCTAssertEqual(merged.updatedAt, refreshed.updatedAt)
        XCTAssertEqual(merged.commit, refreshed.commit)
    }

    func testLegacyStageCacheKeepsLogsAndRequiresFinalRefreshAfterCompletion() throws {
        let repository = project("github:owner/example")
        let running = Pipeline(
            id: "github-1", projectID: repository.id, provider: repository.provider, repository: repository.repository,
            branch: "main", commit: "old", duration: "2 sec", state: .running,
            stages: [PipelineStage(id: "job-1", name: "Build", duration: "1 sec", state: .success, log: "cached log")],
            updatedAt: Date(timeIntervalSince1970: 100), webURL: nil, hasLoadedStages: true
        )
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(running)) as? [String: Any])
        legacyJSON.removeValue(forKey: "stageSnapshotState")
        let legacy = try JSONDecoder().decode(Pipeline.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        let completed = pipeline("github-1", project: repository, timestamp: 200)
        let merged = CIPipelineCache.merging(completed, with: legacy)
        XCTAssertTrue(merged.hasLoadedStages)
        XCTAssertEqual(merged.stages.first?.log, "cached log")
        XCTAssertEqual(merged.stageSnapshotState, .running)

        // A restart after a failed final jobs fetch must retain retry eligibility.
        let restored = try JSONDecoder().decode(Pipeline.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(CIPipelineCache.stageRefreshCandidates(in: [repository.id: [restored]]).count, 1)
        let jobs = [RemoteJob(id: "job-1", name: "Build", stage: "Build", status: "success", duration: "1 sec", log: "")]
        let staged = try XCTUnwrap(CIPipelineCache.withJobs(restored, jobs: jobs))
        let final = CIPipelineCache.merging(staged, with: restored)
        XCTAssertEqual(final.stages.first?.log, "cached log")
        XCTAssertEqual(final.stageSnapshotState, .success)
        XCTAssertTrue(CIPipelineCache.stageRefreshCandidates(in: [repository.id: [final]]).isEmpty)
    }

    @MainActor
    func testPrefetchPublishesEachSuccessBeforeALaterRequestFails() async throws {
        let first = project("github:owner/first")
        let second = project("github:owner/second")
        let candidates: [(String, Pipeline)] = [
            (first.id, pipeline("github-1", project: first, timestamp: 200)),
            (second.id, pipeline("github-2", project: second, timestamp: 100))
        ]
        var published: [String: Pipeline] = [:]
        do {
            _ = try await prefetchPipelineStages(candidates: candidates, limit: 8, onLoad: { projectID, loaded in
                published[projectID] = loaded
            }) { pipeline in
                if pipeline.projectID == second.id { throw URLError(.timedOut) }
                return [RemoteJob(id: "job-1", name: "Build", stage: "Build", status: "success", duration: "1 sec", log: "")]
            }
            XCTFail("Expected the second jobs request to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(published.count, 1)
        XCTAssertEqual(published[first.id]?.hasLoadedStages, true)
    }

    func testIncrementalPipelineMergePreservesUnchangedPipelines() {
        let repository = project("gitlab:one:1", provider: "GitLab CI")
        let unchanged = pipeline("gitlab-older", project: repository, timestamp: 100)
        let oldVersion = pipeline("gitlab-current", project: repository, timestamp: 200)
        let refreshed = pipeline("gitlab-current", project: repository, timestamp: 300)

        let merged = CIPipelineCache.mergingRecent([refreshed], with: [oldVersion, unchanged])

        XCTAssertEqual(merged.map(\.id), [refreshed.id, unchanged.id])
        XCTAssertEqual(merged.first?.updatedAt, refreshed.updatedAt)
    }

    func testRefreshProfilerAggregatesRequestTimingsByStep() {
        let startedAt = Date(timeIntervalSince1970: 100)
        let profiler = CIRefreshProfiler(startedAt: startedAt)
        profiler.record("GitLab · 全局流水线", duration: 0.4, requests: 1)
        profiler.record("GitLab · 全局流水线", duration: 0.6, requests: 1)
        profiler.record("GitLab · 作业步骤", duration: 0.2, requests: 2)

        let report = profiler.report(
            completedAt: Date(timeIntervalSince1970: 102),
            projectCount: 3,
            pipelineCount: 7,
            errorCount: 0
        )

        XCTAssertEqual(report.totalDuration, 2)
        XCTAssertEqual(report.components.map(\.name), ["GitLab · 全局流水线", "GitLab · 作业步骤"])
        XCTAssertEqual(report.components.first?.duration, 1)
        XCTAssertEqual(report.components.first?.requestCount, 2)
        XCTAssertEqual(CIRefreshTimingFormatter.duration(0.123), "123 ms")
    }

    func testMenuBarStatusCountsRunningPipelinesAndOnlyUnreadFailures() {
        let repository = project("gitlab:one:1", provider: "GitLab CI")
        let acknowledgedFailure = pipeline("failed-seen", project: repository, timestamp: 100, state: .failed)
        let unreadFailure = pipeline("failed-new", project: repository, timestamp: 200, state: .failed)
        let running = pipeline("running", project: repository, timestamp: 300, state: .running)

        let pipelines = [acknowledgedFailure, unreadFailure, running]
        let acknowledged = [CIPipelineStatusCounter.failureID(for: acknowledgedFailure)]
        let counts = CIPipelineStatusCounter.counts(in: pipelines, acknowledgedFailureIDs: Set(acknowledged))

        XCTAssertEqual(counts.running, 1)
        XCTAssertEqual(counts.unreadFailures, 1)
    }

    func testPrefetchStageLimitDoesNotFetchBeyondSelectedProjects() async {
        let repositories = (1...4).map { project("github:owner/\($0)") }
        let candidates = repositories.enumerated().map { index, repository in
            (repository.id, pipeline("run-\(index)", project: repository, timestamp: TimeInterval(index)))
        }
        let result = await prefetchPipelineStages(candidates: candidates, limit: 2) { pipeline in
            [RemoteJob(id: "job-\(pipeline.id)", name: "build", stage: "build", status: "success", duration: "1 秒", log: "")]
        }

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.values.allSatisfy(\.hasLoadedStages))
    }

    func testOpeningPipelineStagesDoesNotIncludeLogsUntilSelected() {
        let repository = project("gitlab:one:1", provider: "GitLab CI")
        let pipeline = pipeline("gitlab-42", project: repository, timestamp: 100)
        let jobs = [RemoteJob(id: "job-1", name: "build", stage: "build", status: "success", duration: "2 分钟", log: "server log")]

        let detailed = CIPipelineCache.withJobs(pipeline, jobs: jobs)

        XCTAssertEqual(detailed?.stages.count, 1)
        XCTAssertEqual(detailed?.stages.first?.log, "")
    }

    func testGroupsDynamicJobsUnderTheirProviderStage() {
        let repository = project("gitlab:one:1", provider: "GitLab CI")
        let pipeline = pipeline("gitlab-42", project: repository, timestamp: 100)
        let jobs = [
            RemoteJob(id: "job-1", name: "docker-release: [admin]", stage: "build", status: "success", duration: "1 分钟", log: ""),
            RemoteJob(id: "job-2", name: "docker-release: [agent]", stage: "build", status: "running", duration: "—", log: ""),
            RemoteJob(id: "job-3", name: "deploy", stage: "deploy", status: "success", duration: "2 分钟", log: "")
        ]

        let groups = CIPipelineCache.withJobs(pipeline, jobs: jobs)?.stages.groupedPipelineStages

        XCTAssertEqual(groups?.map(\.name), ["build", "deploy"])
        XCTAssertEqual(groups?.first?.jobs.map(\.name), ["docker-release: [admin]", "docker-release: [agent]"])
        XCTAssertEqual(groups?.first?.state, .running)
        XCTAssertEqual(groups?.last?.jobs.count, 1)
    }

    private func project(
        _ id: String,
        name: String? = nil,
        provider: String = "GitHub Actions",
        timestamp: TimeInterval? = nil
    ) -> CIAccessibleProject {
        CIAccessibleProject(
            id: id, name: name ?? id, provider: provider, repository: id, branch: "main",
            instanceName: nil, updatedAt: timestamp.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func pipeline(
        _ id: String,
        project: CIAccessibleProject,
        timestamp: TimeInterval?,
        state: PipelineState = .success
    ) -> Pipeline {
        Pipeline(
            id: id, projectID: project.id, provider: project.provider, repository: project.repository,
            branch: "main", commit: "test", duration: "—", state: state, stages: [],
            updatedAt: timestamp.map { Date(timeIntervalSince1970: $0) }, webURL: nil
        )
    }
}
