import Foundation

/// Await each request before delaying, so slow providers never overlap polls.
/// The view owns this task; leaving the log viewer cancels requests and sleep.
enum CILogPolling {
    @MainActor
    static func run(interval: Duration = .seconds(3), refresh: () async -> Bool) async {
        while !Task.isCancelled {
            guard await refresh(), !Task.isCancelled else { return }
            do { try await Task.sleep(for: interval) } catch { return }
        }
    }
}
