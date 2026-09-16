import Foundation

/// One latest pipeline per project, preserving the existing activity-card layout.
struct CIProjectActivity: Identifiable {
    let project: CIAccessibleProject
    let pipeline: Pipeline

    var id: String { project.id }
}

enum CIActivityOrdering {
    static let activityDisplayLimit = 20
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
            guard let pipeline = pipelineCache[project.id]?.min(by: newestFirst) else { return nil }
            return CIProjectActivity(project: project, pipeline: pipeline)
        }.sorted { lhs, rhs in
            if lhs.pipeline.updatedAt == rhs.pipeline.updatedAt {
                return lhs.id < rhs.id
            }
            return newestFirst(lhs.pipeline, rhs.pipeline)
        }.prefix(activityDisplayLimit).map { $0 }
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
            pipelineCache[project.id]?.contains { $0.state.needsStatusRefresh } == true ? project.id : nil
        })
        return projects.filter { runningIDs.contains($0.id) } + projects.filter { !runningIDs.contains($0.id) }
    }

    /// Apply one hard limit, including urgent projects. Reserve a small share
    /// for older projects so sustained activity cannot starve the rest.
    static func gitLabProjectsRequiringPipelineRefresh(
        projects: [CIAccessibleProject],
        pipelineCache: [String: [Pipeline]],
        followedIDs: Set<String>,
        successfulPolls: [String: Date],
        attemptedPolls: [String: Date],
        batchSize: Int
    ) -> [CIAccessibleProject] {
        let projects = uniqueProjects(projects)
        let limit = max(0, batchSize)
        guard limit > 0 else { return [] }
        let recentIDs = Set(projects.prefix(limit).map(\.id))
        let trackedIDs = Set(projects.filter { project in
            followedIDs.contains(project.id) ||
                pipelineCache[project.id]?.contains { $0.state.needsStatusRefresh } == true
        }.map(\.id))
        let changedIDs = Set(projects.filter { project in
            project.updatedAt.map { $0 > (successfulPolls[project.id] ?? .distantPast) } == true
        }.map(\.id))
        func lastPoll(_ project: CIAccessibleProject) -> Date {
            attemptedPolls[project.id] ?? successfulPolls[project.id] ?? .distantPast
        }
        func rank(_ project: CIAccessibleProject) -> Int {
            trackedIDs.contains(project.id) ? 0 : changedIDs.contains(project.id) ? 1 : 2
        }
        let ordered = projects.enumerated().sorted { lhs, rhs in
            let left = lastPoll(lhs.element), right = lastPoll(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }
        let backgroundSlots = projects.count > limit ? min(2, limit / 4) : 0
        let priority = ordered.filter {
            trackedIDs.contains($0.element.id) || changedIDs.contains($0.element.id) || recentIDs.contains($0.element.id)
        }.sorted { lhs, rhs in
            let leftRank = rank(lhs.element), rightRank = rank(rhs.element)
            if leftRank != rightRank { return leftRank < rightRank }
            let left = lastPoll(lhs.element), right = lastPoll(rhs.element)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.prefix(limit - backgroundSlots).map(\.element)
        let priorityIDs = Set(priority.map(\.id))
        let background = ordered
            .filter { !priorityIDs.contains($0.element.id) }
            .prefix(limit - priority.count)
            .map(\.element)
        return priority + background
    }
}
