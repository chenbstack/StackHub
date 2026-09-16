import SwiftUI

/// Keep provider states distinct: a created/skipped/manual job is not a failure.
/// Existing success/failed/running raw values remain compatible with saved data.
enum PipelineState: String, Codable {
    case success, failed, running, pending, manual, scheduled, skipped, canceled, unknown

    init(remoteStatus: String) {
        switch remoteStatus.lowercased() {
        case "success", "passed", "completed", "neutral": self = .success
        case "failed", "failure", "timed_out", "startup_failure": self = .failed
        case "running", "in_progress", "in progress", "preparing", "canceling": self = .running
        case "created", "pending", "queued", "waiting", "waiting_for_resource", "waiting_for_callback", "requested": self = .pending
        case "manual", "blocked", "action_required": self = .manual
        case "scheduled": self = .scheduled
        case "skipped": self = .skipped
        case "canceled", "cancelled", "stale": self = .canceled
        default: self = .unknown
        }
    }

    var isInProgress: Bool { self == .running || self == .pending }
    var needsStatusRefresh: Bool { isInProgress || self == .manual || self == .scheduled || self == .unknown }

    var color: Color {
        switch self {
        case .success: return .green
        case .failed: return .red
        case .running: return .blue
        case .manual, .scheduled: return .orange
        case .pending, .skipped, .canceled, .unknown: return .gray
        }
    }

    var label: String {
        switch self {
        case .success: return L("成功")
        case .failed: return L("失败")
        case .running: return L("运行中")
        case .pending: return L("等待中")
        case .manual: return L("等待手动操作")
        case .scheduled: return L("等待定时运行")
        case .skipped: return L("已跳过")
        case .canceled: return L("已取消")
        case .unknown: return L("未知状态")
        }
    }

    static func aggregate(_ states: [PipelineState]) -> PipelineState {
        guard !states.isEmpty else { return .unknown }
        for state in [failed, running, pending, manual, scheduled, canceled, unknown] where states.contains(state) {
            return state
        }
        return states.contains(.success) ? .success : .skipped
    }
}
