import Foundation

enum CIHTTPTransport {
    static let timeout: TimeInterval = 3
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
}

enum CISource: Hashable {
    case github
    case gitlab(UUID)

    func contains(projectID: String) -> Bool {
        switch self {
        case .github: return projectID.hasPrefix("github:")
        case .gitlab(let id): return projectID.hasPrefix("gitlab:\(id.uuidString):")
        }
    }
}

enum CIConnectionFailure {
    static func isOffline(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .networkConnectionLost, .notConnectedToInternet, .internationalRoamingOff,
             .callIsActive, .dataNotAllowed:
            return true
        default: return false
        }
    }

    static func shouldStopRequests(_ error: Error) -> Bool {
        isOffline(error) || error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// Optional metadata may fail independently. A lost connection ends the
/// instance's refresh instead of paying the timeout for every remaining item.
@MainActor
func optionalCIRequest<T>(_ operation: () async throws -> T) async throws -> T? {
    do { return try await operation() }
    catch {
        if CIConnectionFailure.shouldStopRequests(error) { throw error }
        return nil
    }
}

/// All scheduling and credentials stay on the main actor. Only suspended
/// network requests overlap; no shared decoder or Keychain access is raced.
@MainActor
final class CIRefreshScheduler {
    private struct State {
        var requestID: UUID?
        var nextAutomaticRefresh: Date = .distantPast
        var consecutiveConnectionFailures = 0
    }

    private var states: [CISource: State] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    var isRefreshing: Bool { states.values.contains { $0.requestID != nil } }

    func isRefreshing(_ source: CISource) -> Bool { states[source]?.requestID != nil }

    func begin(_ source: CISource, manual: Bool) -> UUID? {
        var state = states[source] ?? State()
        // Skip overlapping ticks and manual clicks; do not queue another round.
        // The source stays busy until its summaries and detail prefetch finish.
        guard state.requestID == nil, manual || now() >= state.nextAutomaticRefresh else { return nil }
        let id = UUID()
        state.requestID = id
        states[source] = state
        return id
    }

    func isCurrent(_ source: CISource, requestID: UUID) -> Bool {
        states[source]?.requestID == requestID
    }

    func finish(_ source: CISource, requestID: UUID, connectionFailed: Bool) {
        guard var state = states[source], state.requestID == requestID else { return }
        state.requestID = nil
        state.consecutiveConnectionFailures = connectionFailed ? min(state.consecutiveConnectionFailures + 1, 4) : 0
        let delay = connectionFailed
            ? min(60 * pow(2, Double(state.consecutiveConnectionFailures - 1)), 300)
            : StackHubStore.ciRefreshInterval
        state.nextAutomaticRefresh = now().addingTimeInterval(delay)
        states[source] = state
    }

    func invalidate(_ source: CISource) { states.removeValue(forKey: source) }
}

/// Injection keeps network regression tests independent of the user's Keychain.
struct CICredentialProvider {
    var github: @MainActor () async -> String?
    var gitlab: @MainActor (GitLabInstance) -> String?
}
