import Darwin
import Foundation

enum ServicePortGuardError: LocalizedError {
    case invalidPort(Int)
    case inspectionFailed(port: Int, detail: String)
    case protectsStackHub(port: Int)
    case terminationFailed(port: Int, pid: Int32, signal: Int32, errno: Int32)
    case stillOccupied(port: Int, pids: [Int32])

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            return "端口必须在 1–65535 之间"
        case .inspectionFailed(_, let detail):
            return "无法检查端口占用（\(detail)）"
        case .protectsStackHub:
            return "该端口正由 StackHub 自身占用，为避免关闭应用未处理"
        case .terminationFailed(_, let pid, let signal, let code):
            return "无法向 PID \(pid) 发送信号 \(signal)（错误码 \(code)）"
        case .stillOccupied(_, let pids):
            return "PID \(pids.map(String.init).joined(separator: ", ")) 仍在监听"
        }
    }
}

/// Releases only a port that the user explicitly configured on a service.
/// It uses Process arguments rather than a shell command, so the port value is
/// never interpolated into executable shell text.
enum ServicePortGuard {
    static func configuredPort(from raw: String) -> Int? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(value), (1...65_535).contains(port) else { return nil }
        return port
    }

    static func configuredPorts(from raw: String) -> [Int]? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return [] }

        var seen: Set<Int> = []
        var ports: [Int] = []
        for component in value.split(separator: ",", omittingEmptySubsequences: false) {
            guard let port = configuredPort(from: String(component)), seen.insert(port).inserted else {
                return nil
            }
            ports.append(port)
        }
        return ports
    }

    static func hasValidConfiguration(_ raw: String) -> Bool {
        configuredPorts(from: raw) != nil
    }

    @discardableResult
    static func release(port: Int) throws -> [Int32] {
        guard (1...65_535).contains(port) else { throw ServicePortGuardError.invalidPort(port) }

        let initiallyListening = try listenerProcessIDs(on: port)
        guard !initiallyListening.isEmpty else { return [] }

        let stackHubPID = Int32(ProcessInfo.processInfo.processIdentifier)
        guard !initiallyListening.contains(stackHubPID) else {
            throw ServicePortGuardError.protectsStackHub(port: port)
        }

        try send(SIGTERM, to: initiallyListening, on: port)
        var remaining = try waitForRelease(of: port)
        if !remaining.isEmpty {
            try send(SIGKILL, to: remaining, on: port)
            remaining = try waitForRelease(of: port)
        }
        guard remaining.isEmpty else {
            throw ServicePortGuardError.stillOccupied(port: port, pids: remaining)
        }
        return initiallyListening
    }

    static func listenerProcessIDs(from output: String) -> [Int32] {
        Array(Set(output.split(whereSeparator: { $0.isNewline }).compactMap { Int32(String($0)) })).sorted()
    }

    private static func listenerProcessIDs(on port: Int) throws -> [Int32] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ServicePortGuardError.inspectionFailed(port: port, detail: error.localizedDescription)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // lsof uses exit status 1 when no matching file descriptor exists.
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw ServicePortGuardError.inspectionFailed(port: port, detail: "lsof 退出码 \(process.terminationStatus)")
        }
        return listenerProcessIDs(from: String(decoding: data, as: UTF8.self))
    }

    private static func send(_ signal: Int32, to pids: [Int32], on port: Int) throws {
        for pid in pids where Darwin.kill(pid, signal) == -1 {
            let errorCode = errno
            // The process can exit between lsof and kill. In that case it has
            // already stopped occupying the configured port.
            guard errorCode != ESRCH else { continue }
            throw ServicePortGuardError.terminationFailed(port: port, pid: pid, signal: signal, errno: errorCode)
        }
    }

    private static func waitForRelease(of port: Int) throws -> [Int32] {
        var remaining: [Int32] = []
        for _ in 0..<6 {
            remaining = try listenerProcessIDs(on: port)
            if remaining.isEmpty { return [] }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return try listenerProcessIDs(on: port)
    }
}
