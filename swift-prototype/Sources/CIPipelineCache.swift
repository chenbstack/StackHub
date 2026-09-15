import Foundation

enum CIPipelineCache {
    /// Replace the summary placeholder with job/stage statuses while retaining
    /// logs that were loaded earlier for the same job.
    static func merging(_ refreshed: Pipeline, with previous: Pipeline?) -> Pipeline {
        guard let previous, previous.hasLoadedStages else { return refreshed }

        if !refreshed.hasLoadedStages {
            return copy(refreshed, stages: previous.stages, hasLoadedStages: true)
        }

        let previousByID = Dictionary(uniqueKeysWithValues: previous.stages.map { ($0.id, $0) })
        let stages = refreshed.stages.map { stage in
            guard let old = previousByID[stage.id], !old.log.isEmpty else { return stage }
            return PipelineStage(id: stage.id, name: stage.name, duration: stage.duration, state: stage.state, log: old.log)
        }
        return copy(refreshed, stages: stages, hasLoadedStages: true)
    }

    static func withJobs(_ pipeline: Pipeline, jobs: [RemoteJob]) -> Pipeline? {
        guard !jobs.isEmpty else { return nil }
        let stages = jobs.map { job in
            PipelineStage(
                id: job.id,
                name: job.stage.isEmpty ? job.name : "\(job.stage) · \(job.name)",
                duration: job.duration,
                state: job.state,
                log: ""
            )
        }
        return copy(pipeline, stages: stages, hasLoadedStages: true)
    }

    private static func copy(_ pipeline: Pipeline, stages: [PipelineStage], hasLoadedStages: Bool) -> Pipeline {
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
            hasLoadedStages: hasLoadedStages
        )
    }
}

/// Prefetch stage statuses for a small, time-ordered set of projects. Logs
/// remain lazy and are fetched only when the user opens a pipeline.
func prefetchPipelineStages(
    candidates: [(String, Pipeline)],
    limit: Int,
    fetchJobs: @escaping (Pipeline) async -> [RemoteJob]
) async -> [String: Pipeline] {
    let selected = Array(candidates
        .sorted { CIActivityOrdering.newestFirst($0.1, $1.1) }
        .prefix(max(limit, 0)))
    guard !selected.isEmpty else { return [:] }

    var result: [String: Pipeline] = [:]
    for start in stride(from: 0, to: selected.count, by: 4) {
        let end = min(start + 4, selected.count)
        let batch = Array(selected[start..<end])
        var fetched: [(String, Pipeline?)] = []
        for (projectID, pipeline) in batch {
            let jobs = await fetchJobs(pipeline)
            fetched.append((projectID, CIPipelineCache.withJobs(pipeline, jobs: jobs)))
        }
        for (projectID, pipeline) in fetched {
            if let pipeline { result[projectID] = pipeline }
        }
    }
    return result
}
