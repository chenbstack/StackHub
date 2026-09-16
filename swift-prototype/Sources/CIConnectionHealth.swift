import Foundation

enum CIConnectionState: Equatable {
    case unchecked, checking, connected, unconfigured, unauthorized, forbidden, unreachable, failed

    var label: String {
        switch self {
        case .unchecked: return L("尚未检测")
        case .checking: return L("检测中…")
        case .connected: return L("连接正常")
        case .unconfigured: return L("尚未配置访问令牌")
        case .unauthorized: return L("认证失败，请重新授权")
        case .forbidden: return L("访问被拒绝，请检查权限")
        case .unreachable: return L("无法连接")
        case .failed: return L("检测失败")
        }
    }
}

struct CIConnectionStatus: Equatable {
    var state: CIConnectionState
    var checkedAt: Date? = nil
    var duration: TimeInterval? = nil
    var detail: String? = nil

    static func failure(_ error: Error) -> CIConnectionStatus {
        let state: CIConnectionState
        let detail: String
        switch error {
        case CIIntegrationError.missingToken:
            state = .unconfigured
            detail = state.label
        case CIIntegrationError.http(let code, _):
            state = code == 401 ? .unauthorized : code == 403 ? .forbidden : .failed
            detail = "HTTP \(code)"
        default:
            state = CIConnectionFailure.isOffline(error) ? .unreachable : .failed
            detail = error.localizedDescription
        }
        return CIConnectionStatus(state: state, checkedAt: Date(), detail: detail)
    }
}

/// An authenticated endpoint must return an actual account, not a sign-in page.
struct CIAuthenticatedUser: Decodable {
    let id: Int
}
