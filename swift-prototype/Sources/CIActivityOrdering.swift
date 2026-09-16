import Foundation

/// One latest pipeline per project, preserving the existing activity-card layout.
struct CIProjectActivity: Identifiable {
    let project: CIAccessibleProject
    let pipeline: Pipeline

    var id: String { project.id }
}

enum CIActivityOrdering {
    /// Use the same timestamp as the activity card, regardless of provider.
    /// Missing timestamps sort last; stable IDs break ties across refreshes.
    static func newestFirst(_ lhs: Pipeline, _ rhs: Pipeline) -> Bool {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            return lhs.id < rhs.id
        }
    }

    static func latestActivities(
        projects: [CIAccessibleProject],
        pipelineCache: [String: [Pipeline]]
    ) -> [CIProjectActivity] {
        uniqueProjects(projects).compactMap { project -> CIProjectActivity? in
            // API response order can differ from pipeline update order.
            guard let pipeline = pipelineCache[project.id]?.sorted(by: newestFirst).first else { return nil }
            return CIProjectActivity(project: project, pipeline: pipeline)
        }.sorted { lhs, rhs in
            if lhs.pipeline.updatedAt == rhs.pipeline.updatedAt {
                return lhs.id < rhs.id
            }
            return newestFirst(lhs.pipeline, rhs.pipeline)
        }
    }

    /// Keep the API's recently-active repository order for bounded requests.
    /// Dictionary iteration must not choose which projects get synchronized.
    static func uniqueProjects(_ projects: [CIAccessibleProject]) -> [CIAccessibleProject] {
        var seenIDs = Set<String>()
        return projects.filter { seenIDs.insert($0.id).inserted }
    }

    /// Retain the bounded GitHub repository scope while replacing cached
    /// metadata with the repositories returned by an incremental `since` query.
    static func mergedRecentProjects(
        changed: [CIAccessibleProject],
        cached: [CIAccessibleProject],
        limit: Int
    ) -> [CIAccessibleProject] {
        uniqueProjects(changed + cached)
            .sorted { lhs, rhs in
                switch (lhs.updatedAt, rhs.updatedAt) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.id < rhs.id
                }
            }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    /// Actions can start, finish, or rerun without changing repository metadata.
    /// Poll the bounded dashboard scope every cycle, prioritizing active runs.
    static func projectsRequiringPipelineRefresh(
        retained: [CIAccessibleProject],
        pipelineCache: [String: [Pipeline]]
    ) -> [CIAccessibleProject] {
        let projects = uniqueProjects(retained)
        let runningIDs = Set(projects.compactMap { project in
            pipelineCache[project.id]?.contains { $0.state == .running } == true ? project.id : nil
        })
        return projects.filter { runningIDs.contains($0.id) } + projects.filter { !runningIDs.contains($0.id) }
    }

    /// The first batch follows fresh server activity. Followed/running projects
    /// and activity newer than the last successful poll must not be cut off by
    /// that batch size. Rotate through the rest to catch retries and schedules
    /// that do not update GitLab's project activity timestamp.
    static func gitLabProjectsRequiringPipelineRefresh(
        projects: [CIAccessibleProject],
        pipelineCache: [String: [Pipeline]],
        followedIDs: Set<String>,
        successfulPolls: [String: Date],
        attemptedPolls: [String: Date],
        batchSize: Int
    ) -> [CIAccessibleProject] {
        let projects = uniqueProjects(projects)
        let recent = Array(projects.prefix(max(0, batchSize)))
        let urgent = projects.filter { project in
            followedIDs.contains(project.id) ||
                pipelineCache[project.id]?.contains { $0.state == .running } == true ||
                project.updatedAt.map { $0 > (successfulPolls[project.id] ?? .distantPast) } == true
        }
        let priority = uniqueProjects(recent + urgent)
        let priorityIDs = Set(priority.map(\.id))
        let background = projects.enumerated()
            .filter { !priorityIDs.contains($0.element.id) }
            .sorted { lhs, rhs in
                let left = attemptedPolls[lhs.element.id] ?? successfulPolls[lhs.element.id] ?? .distantPast
                let right = attemptedPolls[rhs.element.id] ?? successfulPolls[rhs.element.id] ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .prefix(max(0, batchSize))
            .map(\.element)
        return priority + background
    }
}
