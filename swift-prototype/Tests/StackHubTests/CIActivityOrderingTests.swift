import Foundation
import XCTest
@testable import StackHub

final class CIActivityOrderingTests: XCTestCase {
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

    func testIncrementalGitHubMergeRefreshesOnlyChangedProjectsInRetainedScope() {
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
            changed: [changed, newlyRecent],
            retained: retained
        )

        XCTAssertEqual(retained.map(\.id), [newlyRecent.id, changed.id])
        XCTAssertEqual(retained.last?.name, "Changed metadata")
        XCTAssertEqual(refresh.map(\.id), [changed.id, newlyRecent.id])
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

    private func pipeline(_ id: String, project: CIAccessibleProject, timestamp: TimeInterval?) -> Pipeline {
        Pipeline(
            id: id, projectID: project.id, provider: project.provider, repository: project.repository,
            branch: "main", commit: "test", duration: "—", state: .success, stages: [],
            updatedAt: timestamp.map { Date(timeIntervalSince1970: $0) }, webURL: nil
        )
    }
}
