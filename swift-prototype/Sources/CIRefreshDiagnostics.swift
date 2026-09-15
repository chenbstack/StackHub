import Foundation
import OSLog

struct CIRefreshTimingComponent: Identifiable {
    let id: String
    let name: String
    let duration: TimeInterval
    let requestCount: Int
}

struct CIRefreshReport: Identifiable {
    let id = UUID()
    let completedAt: Date
    let totalDuration: TimeInterval
    let projectCount: Int
    let pipelineCount: Int
    let errorCount: Int
    let components: [CIRefreshTimingComponent]
}

/// Aggregates timings inside one source's CI refresh. It deliberately records
/// provider requests separately from local cache work so slow refreshes can be
/// traced to a concrete API or processing step in the panel's refresh log.
final class CIRefreshProfiler {
    private struct Accumulator {
        var duration: TimeInterval = 0
        var requestCount = 0
    }

    private let startedAt: Date
    private var accumulators: [String: Accumulator] = [:]

    init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    func record(_ name: String, duration: TimeInterval, requests: Int = 0) {
        var accumulator = accumulators[name] ?? Accumulator()
        accumulator.duration += max(0, duration)
        accumulator.requestCount += max(0, requests)
        accumulators[name] = accumulator
    }

    func measure<T>(
        _ name: String,
        requests: Int = 0,
        operation: () async throws -> T
    ) async rethrows -> T {
        let startedAt = Date()
        defer { record(name, duration: Date().timeIntervalSince(startedAt), requests: requests) }
        return try await operation()
    }

    func report(
        completedAt: Date = Date(),
        projectCount: Int,
        pipelineCount: Int,
        errorCount: Int
    ) -> CIRefreshReport {
        let components = accumulators.map { name, accumulator in
            CIRefreshTimingComponent(
                id: name, name: name, duration: accumulator.duration,
                requestCount: accumulator.requestCount
            )
        }
        .sorted {
            if $0.duration != $1.duration { return $0.duration > $1.duration }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return CIRefreshReport(
            completedAt: completedAt,
            totalDuration: max(0, completedAt.timeIntervalSince(startedAt)),
            projectCount: projectCount,
            pipelineCount: pipelineCount,
            errorCount: errorCount,
            components: components
        )
    }
}

enum CIRefreshTimingFormatter {
    static func duration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(max(0, Int((duration * 1_000).rounded()))) ms"
        }
        return String(format: "%.2f 秒", duration)
    }
}

enum CIRefreshDiagnostics {
    private static let logger = Logger(subsystem: "com.stackhub.prototype", category: "ci-refresh")

    /// Write compact records to the macOS system log. This is intentionally
    /// diagnostic-only: it does not create a UI surface or retain new
    /// user-visible logs.
    static func write(_ report: CIRefreshReport) {
        let summary = "[CI refresh] total=\(CIRefreshTimingFormatter.duration(report.totalDuration)) projects=\(report.projectCount) pipelines=\(report.pipelineCount) errors=\(report.errorCount)"
        let details = report.components.map { component in
            let requests = component.requestCount > 0 ? " requests=\(component.requestCount)" : ""
            return "[CI refresh] \(component.name) duration=\(CIRefreshTimingFormatter.duration(component.duration))\(requests)"
        }
        // Explicitly mark these values public. `NSLog` redacts the complete
        // message in unified logging, which makes timing diagnostics useless
        // when investigating a slow refresh.
        ([summary] + details).forEach { logger.info("\($0, privacy: .public)") }
    }
}

struct CIPipelineStatusCounts: Equatable {
    let running: Int
    let unreadFailures: Int

    var hasVisibleCount: Bool { running > 0 || unreadFailures > 0 }
}

enum CIPipelineStatusCounter {
    /// Pipeline IDs are provider- and project-scoped so two GitLab instances
    /// with the same numeric run ID never acknowledge one another.
    static func failureID(for pipeline: Pipeline) -> String {
        "\(pipeline.provider)|\(pipeline.projectID)|\(pipeline.id)"
    }

    static func failedPipelineIDs(in cache: [String: [Pipeline]]) -> Set<String> {
        Set(cache.values.lazy.flatMap { $0 }.compactMap { pipeline in
            pipeline.state == .failed ? failureID(for: pipeline) : nil
        })
    }

    static func counts(
        in cache: [String: [Pipeline]],
        acknowledgedFailureIDs: Set<String>
    ) -> CIPipelineStatusCounts {
        let pipelines = cache.values.lazy.flatMap { $0 }
        let running = pipelines.filter { $0.state == .running }.count
        let failures = failedPipelineIDs(in: cache)
        return CIPipelineStatusCounts(
            running: running,
            unreadFailures: failures.subtracting(acknowledgedFailureIDs).count
        )
    }
}
