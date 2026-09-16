import Foundation
import Darwin

enum RuntimeKind: String, CaseIterable, Codable, Sendable {
    case java, node
    var title: String { self == .java ? "JDK" : "Node.js" }
    var versionFiles: [String] { self == .java ? [".java-version"] : [".nvmrc", ".node-version"] }
}

enum RuntimeMode: String, CaseIterable, Codable, Sendable {
    case automatic, installed, custom
    var label: String {
        switch self {
        case .automatic: return L("自动（项目配置 / Shell 默认）")
        case .installed: return L("已安装版本")
        case .custom: return L("自定义路径")
        }
    }
}

struct RuntimeChoice: Codable, Hashable, Sendable {
    var mode: RuntimeMode = .automatic
    var path: String = ""
}

struct ServiceRuntimeConfiguration: Codable, Hashable, Sendable {
    var java = RuntimeChoice()
    var node = RuntimeChoice()
    subscript(kind: RuntimeKind) -> RuntimeChoice {
        get { kind == .java ? java : node }
        set { if kind == .java { java = newValue } else { node = newValue } }
    }
}

struct RuntimeInstallation: Identifiable, Equatable, Sendable {
    let kind: RuntimeKind
    let version: String
    /// JDK home or Node executable, with symlinks resolved.
    let path: String
    var id: String { path }
    var binDirectory: String {
        kind == .java ? path + "/bin" : URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
}

struct ResolvedRuntime: Sendable {
    let installation: RuntimeInstallation?
    let source: String
}

struct ServiceRuntimeResolution: Sendable {
    var java: ResolvedRuntime
    var node: ResolvedRuntime
    subscript(kind: RuntimeKind) -> ResolvedRuntime { kind == .java ? java : node }
    var logDescription: String {
        RuntimeKind.allCases.compactMap { kind -> String? in
            let item = self[kind]
            guard let runtime = item.installation else { return nil }
            return "[StackHub] \(kind.title) \(runtime.version) · \(item.source)\n  \(runtime.path)\n"
        }.joined()
    }
}

struct RuntimeConfigurationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// All discovery and version commands run off the main thread, with bounded
/// subprocess lifetimes. Only installed tools are used; no install commands run.
struct ServiceRuntimeResolver: Sendable {
    var environment = ProcessInfo.processInfo.environment
    var home = FileManager.default.homeDirectoryForCurrentUser
    var javaRoots: [URL]? = nil
    var nodeRoots: [URL]? = nil
    var timeout: TimeInterval = 5

    struct ShellEnvironment {
        var java: String
        var node: String
        var nvmDirectory: String
        var jenvRoot: String
        var requestedNode: String
    }

    struct VersionRequest: Equatable {
        let value: String
        let file: URL
    }

    func prepare(configuration: ServiceRuntimeConfiguration, directory: URL) async throws -> ServiceRuntimeResolution {
        let work = Task.detached(priority: .userInitiated) { try resolve(configuration: configuration, directory: directory) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func catalog(directory: URL) async throws -> [RuntimeInstallation] {
        let work = Task.detached(priority: .userInitiated) { try discover(directory: directory) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func resolve(configuration: ServiceRuntimeConfiguration, directory: URL) throws -> ServiceRuntimeResolution {
        try Task.checkCancellation()
        let javaRequest = configuration.java.mode == .automatic ? try versionRequest(.java, directory: directory) : nil
        let nodeRequest = configuration.node.mode == .automatic ? try versionRequest(.node, directory: directory) : nil
        let shell = try shellEnvironment(directory: directory, nodeRequest: nodeRequest?.value)
        return ServiceRuntimeResolution(
            java: try resolve(.java, choice: configuration.java, request: javaRequest, shell: shell, directory: directory),
            node: try resolve(.node, choice: configuration.node, request: nodeRequest, shell: shell, directory: directory)
        )
    }

    func discover(directory: URL) throws -> [RuntimeInstallation] {
        let shell = try shellEnvironment(directory: directory)
        return RuntimeKind.allCases.flatMap { kind in
            installations(kind, shell: shell, directory: directory)
        }
    }

    func versionRequest(_ kind: RuntimeKind, directory: URL) throws -> VersionRequest? {
        var current = directory.standardizedFileURL
        while true {
            try Task.checkCancellation()
            for name in kind.versionFiles {
                let file = current.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let contents = try String(contentsOf: file, encoding: .utf8)
                let lines = contents.components(separatedBy: .newlines).map {
                    $0.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespacesAndNewlines)
                }.filter { !$0.isEmpty }
                guard lines.count == 1, let value = lines.first,
                      value.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9._/*+\-]*$"#, options: .regularExpression) != nil,
                      !value.contains("..") else {
                    throw RuntimeConfigurationError(message: LF("版本文件无效：%@", file.path))
                }
                return VersionRequest(value: value, file: file)
            }
            // URL.deletingLastPathComponent can keep appending /.. at the
            // filesystem root. Stop explicitly and rebuild a normalized URL.
            if current.path == "/" { return nil }
            let parent = (current.path as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == current.path { return nil }
            current = URL(fileURLWithPath: parent, isDirectory: true)
        }
    }

    private func resolve(_ kind: RuntimeKind, choice: RuntimeChoice, request: VersionRequest?, shell: ShellEnvironment, directory: URL) throws -> ResolvedRuntime {
        try Task.checkCancellation()
        if choice.mode != .automatic {
            guard !choice.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuntimeConfigurationError(message: LF("请选择 %@ 的已安装版本或路径", kind.title))
            }
            return ResolvedRuntime(installation: try inspect(kind, path: choice.path, directory: directory), source: choice.mode.label)
        }
        if let request {
            let managerPath: String
            if kind == .node {
                managerPath = shell.requestedNode
            } else {
                // jenv aliases point to real JDKs. Reading them also works without
                // initializing jenv or its export plugin in the user's shell.
                managerPath = URL(fileURLWithPath: shell.jenvRoot).appendingPathComponent("versions").appendingPathComponent(request.value).path
            }
            if !managerPath.isEmpty, let installation = try? inspect(kind, path: managerPath, directory: directory) {
                return ResolvedRuntime(installation: installation, source: request.file.path)
            }
            let candidates = installations(kind, shell: shell, directory: directory)
            if let installation = candidates.first(where: { Self.matches(version: $0.version, request: request.value, kind: kind) }) {
                return ResolvedRuntime(installation: installation, source: request.file.path)
            }
            throw RuntimeConfigurationError(message: LF("未找到 %@ %@（来自 %@）。请安装该版本或在运行环境中选择已安装版本。", kind.title, request.value, request.file.path))
        }
        let path = kind == .java ? shell.java : shell.node
        let installation = path.isEmpty ? nil : try? inspect(kind, path: path, directory: directory)
        // Services may only need one runtime (or neither). An absent shell
        // default is informational; an explicit selection is always required.
        return ResolvedRuntime(installation: installation, source: L("Shell 默认"))
    }

    static func matches(version: String, request: String, kind: RuntimeKind) -> Bool {
        var requested = request.hasPrefix("v") ? String(request.dropFirst()) : request
        var actual = version.hasPrefix("v") ? String(version.dropFirst()) : version
        if kind == .java {
            if actual.hasPrefix("1.") { actual = String(actual.dropFirst(2)) }
            if requested.hasPrefix("1.") { requested = String(requested.dropFirst(2)) }
        }
        guard requested.range(of: #"^\d+(?:[._]\d+)*(?:\+\d+)?$"#, options: .regularExpression) != nil else { return false }
        return actual == requested || actual.hasPrefix(requested + ".") || actual.hasPrefix(requested + "_") || actual.hasPrefix(requested + "+")
    }

    private func shellEnvironment(directory: URL, nodeRequest: String? = nil) throws -> ShellEnvironment {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // A NUL-delimited marker ignores banners from startup files. Requests
        // are positional arguments, never executable shell text.
        process.arguments = ["-lic", #"""
        sh_java="${JAVA_HOME:-}"
        if [[ -z "$sh_java" ]] && (( $+commands[jenv] )); then
            sh_java_bin=$(jenv which java 2>/dev/null) && sh_java="${sh_java_bin:h:h}"
        fi
        [[ -n "$sh_java" ]] || sh_java="${commands[java]:-}"
        # Avoid invoking macOS's Java installation stub on machines without a JDK.
        if [[ "$sh_java" == /usr/bin/java ]]; then
            sh_java=$(/usr/libexec/java_home 2>/dev/null) || sh_java=""
        fi
        sh_node="${commands[node]:-}"
        sh_requested_node=""
        if [[ -n "$1" ]] && (( $+functions[nvm] )); then
            sh_requested_node=$(nvm which "$1" 2>/dev/null) || sh_requested_node=""
        fi
        builtin printf '\0STACKHUB_RUNTIME\0%s\0%s\0%s\0%s\0%s\0' "$sh_java" "$sh_node" "${NVM_DIR:-$HOME/.nvm}" "${JENV_ROOT:-$HOME/.jenv}" "$sh_requested_node"
        """#, "stackhub-runtime", nodeRequest ?? ""]
        process.currentDirectoryURL = directory
        process.environment = environment
        let output = try RuntimeProbe.run(process, timeout: timeout)
        let marker = "\0STACKHUB_RUNTIME\0"
        guard let start = output.range(of: marker, options: .backwards) else {
            throw RuntimeConfigurationError(message: L("无法读取 Shell 环境，请检查 .zshrc"))
        }
        let values = output[start.upperBound...].components(separatedBy: "\0")
        guard values.count >= 5 else { throw RuntimeConfigurationError(message: L("无法读取 Shell 环境，请检查 .zshrc")) }
        return ShellEnvironment(java: values[0], node: values[1], nvmDirectory: values[2], jenvRoot: values[3], requestedNode: values[4])
    }

    private func installations(_ kind: RuntimeKind, shell: ShellEnvironment, directory: URL) -> [RuntimeInstallation] {
        let fm = FileManager.default
        func children(_ path: String) -> [String] {
            (try? fm.contentsOfDirectory(atPath: path).sorted().map { path + "/" + $0 }) ?? []
        }
        var paths: [String] = []
        if kind == .java {
            paths.append(shell.java)
            for root in javaRoots ?? [URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines"), home.appendingPathComponent("Library/Java/JavaVirtualMachines")] {
                paths += children(root.path)
            }
            paths += children(shell.jenvRoot + "/versions")
            for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] where javaRoots == nil {
                paths += children(prefix).filter { URL(fileURLWithPath: $0).lastPathComponent.hasPrefix("openjdk") }.map { $0 + "/libexec/openjdk.jdk" }
            }
        } else {
            paths.append(shell.node)
            for root in nodeRoots ?? [URL(fileURLWithPath: shell.nvmDirectory + "/versions/node")] {
                paths += children(root.path).map { $0 + "/bin/node" }
            }
            if nodeRoots == nil {
                paths += ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
                for prefix in ["/opt/homebrew/opt", "/usr/local/opt"] {
                    paths += children(prefix).filter {
                        let name = URL(fileURLWithPath: $0).lastPathComponent
                        return name == "node" || name.hasPrefix("node@")
                    }.map { $0 + "/bin/node" }
                }
            }
        }
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty }.compactMap { path -> RuntimeInstallation? in
            guard !Task.isCancelled else { return nil }
            let normalized = normalizedPath(kind, path: path, directory: directory)
            guard seen.insert(normalized).inserted else { return nil }
            return try? inspect(kind, path: normalized, directory: directory)
        }.sorted {
            let comparison = $0.version.compare($1.version, options: .numeric)
            return comparison == .orderedSame ? $0.path < $1.path : comparison == .orderedDescending
        }
    }

    private func normalizedPath(_ kind: RuntimeKind, path: String, directory: URL) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        var url = URL(fileURLWithPath: expanded, relativeTo: directory).standardizedFileURL.resolvingSymlinksInPath()
        if kind == .java {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Home/bin/java").path) {
                url.appendPathComponent("Contents/Home")
            } else if url.lastPathComponent == "java" { url = url.deletingLastPathComponent().deletingLastPathComponent() }
        }
        return url.path
    }

    func inspect(_ kind: RuntimeKind, path: String, directory: URL) throws -> RuntimeInstallation {
        let normalized = normalizedPath(kind, path: path, directory: directory)
        let executable = kind == .java ? normalized + "/bin/java" : normalized
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw RuntimeConfigurationError(message: LF("%@ 路径不可用：%@", kind.title, path))
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = kind == .java ? ["-XshowSettings:properties", "-version"] : ["-p", "JSON.stringify({version:process.versions.node,path:process.execPath})"]
        process.currentDirectoryURL = directory
        process.environment = environment
        let output = try RuntimeProbe.run(process, timeout: timeout)
        if kind == .node {
            struct NodeInfo: Decodable { let version: String; let path: String }
            if let info = output.components(separatedBy: .newlines).reversed().compactMap({ try? JSONDecoder().decode(NodeInfo.self, from: Data($0.utf8)) }).first,
               info.version.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil {
                return RuntimeInstallation(kind: kind, version: info.version, path: URL(fileURLWithPath: info.path).resolvingSymlinksInPath().path)
            }
        } else {
            func property(_ key: String) -> String? {
                output.components(separatedBy: .newlines).compactMap { line in
                    let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " = ")
                    return parts.count == 2 && parts[0] == key ? parts[1] : nil
                }.first
            }
            if let version = property("java.version"), let actualHome = property("java.home") {
                var jdkHome = URL(fileURLWithPath: actualHome).resolvingSymlinksInPath()
                // JDK 8 reports its embedded JRE as java.home.
                if jdkHome.lastPathComponent == "jre" { jdkHome = jdkHome.deletingLastPathComponent() }
                guard FileManager.default.isExecutableFile(atPath: jdkHome.appendingPathComponent("bin/javac").path) else {
                    throw RuntimeConfigurationError(message: LF("%@ 路径不是完整 JDK：%@", kind.title, path))
                }
                return RuntimeInstallation(kind: kind, version: version, path: jdkHome.path)
            }
        }
        throw RuntimeConfigurationError(message: LF("无法识别 %@ 版本：%@", kind.title, path))
    }
}

enum RuntimeProbe {
    /// File-backed output avoids pipe deadlocks from startup banners and children
    /// keeping stdout open. Read only a bounded prefix and always remove the file.
    static func run(_ process: Process, timeout: TimeInterval) throws -> String {
        try Task.checkCancellation()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("stackhub-runtime-\(UUID())")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: file) }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning {
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try Task.checkCancellation()
                throw RuntimeConfigurationError(message: L("运行环境检测超时，请检查 Shell 启动配置和运行时路径"))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RuntimeConfigurationError(message: L("运行环境检测失败，请检查 Shell 启动配置和运行时路径"))
        }
        try handle.seek(toOffset: 0)
        return String(decoding: try handle.read(upToCount: 262_144) ?? Data(), as: UTF8.self)
    }
}
