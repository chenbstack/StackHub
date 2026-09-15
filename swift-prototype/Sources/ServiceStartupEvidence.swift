import Foundation

/// Conservative, provider-neutral signals from a managed service's output.
/// A process is not marked healthy merely because its shell command launched.
enum ServiceStartupEvidence: Equatable {
    case ready
    case warning

    static func classify(log: String) -> ServiceStartupEvidence? {
        let normalized = log.lowercased()

        // Check failure first: a later-looking success line must not hide an
        // error emitted during the same launch attempt.
        let errorSignals = [
            "error", "fatal", "exception", "panic", "eaddrinuse", "failed",
            "failure", "unable to", "cannot ", "错误", "异常", "启动失败", "端口占用"
        ]
        if errorSignals.contains(where: { normalized.contains($0) }) { return .warning }

        let readySignals = [
            "listening", "started", "server running", "running on", "ready",
            "compiled successfully", "启动成功", "启动完成", "服务已就绪", "监听端口",
            "http://", "https://"
        ]
        if readySignals.contains(where: { normalized.contains($0) }) { return .ready }

        return nil
    }
}
