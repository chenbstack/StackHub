import Foundation

enum CIPipelineCache {
    /// Dashboard cards show the newest run for each project. Missing details
    /// remain eligible even when an incremental response omits that run.
    static func stageRefreshCandidates(in cache: [String: [Pipeline]]) -> [(String, Pipeline)] {
        cache.compactMap { projectID, runs in
            guard let latest = runs.sorted(by: CIActivityOrdering.newestFirst).first,
                  !latest.hasLoadedStages || latest.state == .running ||
                    latest.stageSnapshotState.map({ $0 != latest.state }) == true ||
                    latest.stages.contains(where: { $0.state == .running }) else { return nil }
            return (projectID, latest)
        }
    }

    /// Incremental providers return only the pipelines that changed since the
    /// last cursor. Merge those summaries into the local recent list instead
    /// of replacing unchanged pipelines from other projects or earlier pages.
    static func mergingRecent(_ refreshed: [Pipeline], with previous: [Pipeline], limit: Int = 5) -> [Pipeline] {
        var merged: [String: Pipeline] = [:]
        for pipeline in previous {
            merged[pipeline.id] = pipeline
        }
        for pipeline in refreshed {
            merged[pipeline.id] = merging(pipeline, with: merged[pipeline.id])
        }
        return merged.values
            .sorted(by: CIActivityOrdering.newestFirst)
            .prefix(max(limit, 0))
            .map { $0 }
    }

    /// Replace the summary placeholder with job/stage statuses while retaining
    /// logs that were loaded earlier for the same job.
    static func merging(_ refreshed: Pipeline, with previous: Pipeline?) -> Pipeline {
        guard let previous, previous.hasLoadedStages else { return refreshed }

        if !refreshed.hasLoadedStages {
            return copy(refreshed, stages: previous.stages, hasLoadedStages: true,
                        stageSnapshotState: previous.stageSnapshotState ?? previous.state)
        }

        let previousByID = Dictionary(uniqueKeysWithValues: previous.stages.map { ($0.id, $0) })
        let stages = refreshed.stages.map { stage in
            guard let old = previousByID[stage.id], !old.log.isEmpty else { return stage }
            return PipelineStage(
                id: stage.id,
                name: stage.name,
                duration: stage.duration,
                state: stage.state,
                log: old.log,
                group: stage.group
            )
        }
        return copy(refreshed, stages: stages, hasLoadedStages: true,
                    stageSnapshotState: refreshed.stageSnapshotState ?? refreshed.state)
    }

    static func withJobs(_ pipeline: Pipeline, jobs: [RemoteJob]) -> Pipeline? {
        guard !jobs.isEmpty else { return nil }
        let stages = jobs.map { job in
            PipelineStage(
                id: job.id,
                name: job.name,
                duration: job.duration,
                state: job.state,
                log: "",
                group: job.stage.isEmpty ? nil : job.stage
            )
        }
        return copy(pipeline, stages: stages, hasLoadedStages: true, stageSnapshotState: pipeline.state)
    }

    private static func copy(_ pipeline: Pipeline, stages: [PipelineStage], hasLoadedStages: Bool,
                             stageSnapshotState: PipelineState) -> Pipeline {
        Pipeline(
            id: pipeline.id,
            projectID: pipeline.projectID,
            provider: pipeline.provider,
            repository: pipeline.repository,
            branch: pipeline.branch,
            commit: pipeline.commit,
            duration: pipeline.duration,
            state: pipeline.state,
            stages: stages,
            updatedAt: pipeline.updatedAt,
            webURL: pipeline.webURL,
            startedAt: pipeline.startedAt,
            hasLoadedStages: hasLoadedStages,
            stageSnapshotState: stageSnapshotState
        )
    }
}

/// Prefetch stage statuses for a small, time-ordered set of projects. Logs
/// remain lazy and are fetched only when the user opens a pipeline.
@MainActor
func prefetchPipelineStages(
    candidates: [(String, Pipeline)],
    limit: Int,
    onLoad: (String, Pipeline) -> Void = { _, _ in },
    fetchJobs: @escaping (Pipeline) async throws -> [RemoteJob]
) async rethrows -> [String: Pipeline] {
    let selected = Array(candidates
        .sorted { CIActivityOrdering.newestFirst($0.1, $1.1) }
        .prefix(max(limit, 0)))
    guard !selected.isEmpty else { return [:] }

    var result: [String: Pipeline] = [:]
    for (projectID, pipeline) in selected {
        let jobs = try await fetchJobs(pipeline)
        if let staged = CIPipelineCache.withJobs(pipeline, jobs: jobs) {
            result[projectID] = staged
            onLoad(projectID, staged)
        }
    }
    return result
}
