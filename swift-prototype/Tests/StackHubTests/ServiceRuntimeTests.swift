import Foundation
import XCTest
@testable import StackHub

final class ServiceRuntimeTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let project: URL
        let jdks: URL
        let nodes: URL
        var resolver: ServiceRuntimeResolver

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-runtime-\(UUID())").resolvingSymlinksInPath()
            project = root.appendingPathComponent("project")
            jdks = root.appendingPathComponent("jdks")
            nodes = root.appendingPathComponent("nodes")
            for directory in [root, project, jdks, nodes] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            var environment = ProcessInfo.processInfo.environment
            environment["ZDOTDIR"] = root.path
            environment["HOME"] = root.path
            environment["JAVA_HOME"] = nil
            environment["JENV_ROOT"] = root.appendingPathComponent("jenv").path
            environment["NVM_DIR"] = root.appendingPathComponent("nvm").path
            resolver = ServiceRuntimeResolver(environment: environment, home: root, javaRoots: [jdks], nodeRoots: [nodes], timeout: 2)
            try startup(java: nil, node: nil)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func startup(java: URL?, node: URL?) throws {
            let bin = node?.deletingLastPathComponent().path ?? "/nonexistent"
            try "export PATH=\(quote(bin)):/usr/bin:/bin\nexport JAVA_HOME=\(quote(java?.path ?? "/missing-jdk"))\n"
                .write(to: root.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        }

        func jdk(_ version: String, name: String? = nil, jreHome: Bool = false) throws -> URL {
            let home = jdks.appendingPathComponent(name ?? "jdk-\(version)")
            let info = "    java.version = \(version)\n    java.home = \(home.path)\(jreHome ? "/jre" : "")\n"
            try executable(home.appendingPathComponent("bin/java"), body: "printf '%s' \(quote(info))")
            try executable(home.appendingPathComponent("bin/javac"), body: "exit 0")
            return home
        }

        func node(_ version: String, name: String? = nil) throws -> URL {
            let binary = nodes.appendingPathComponent(name ?? "v\(version)").appendingPathComponent("bin/node")
            let info = String(decoding: try JSONSerialization.data(withJSONObject: ["version": version, "path": binary.path]), as: UTF8.self)
            try executable(binary, body: "printf '%s\\n' \(quote(info))")
            return binary
        }

        func file(_ name: String, _ contents: String, in directory: URL? = nil) throws {
            try contents.write(to: (directory ?? project).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        func executable(_ url: URL, body: String) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    }

    func testProjectFilesSelectInstalledRuntimesWithoutVersionManagers() throws {
        let fixture = try Fixture()
        let java17 = try fixture.jdk("17.0.12")
        let java21 = try fixture.jdk("21.0.11")
        let node18 = try fixture.node("18.20.8")
        let node22 = try fixture.node("22.16.0")
        try fixture.startup(java: java21, node: node22)
        try fixture.file(".java-version", "17\n")
        try fixture.file(".nvmrc", "v18 # app runtime\n")
        let subdirectory = fixture.project.appendingPathComponent("backend")
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let resolved = try fixture.resolver.resolve(configuration: .init(), directory: subdirectory)
        XCTAssertEqual(resolved.java.installation?.path, java17.path)
        XCTAssertEqual(resolved.node.installation?.path, node18.path)
        XCTAssertEqual(resolved.java.source, fixture.project.appendingPathComponent(".java-version").path)
        XCTAssertEqual(resolved.node.source, fixture.project.appendingPathComponent(".nvmrc").path)
        // The nearest supported version file wins, even if an ancestor has .nvmrc.
        try fixture.file(".node-version", "22", in: subdirectory)
        XCTAssertEqual(try fixture.resolver.resolve(configuration: .init(), directory: subdirectory).node.installation?.path, node22.path)
    }

    func testShellDefaultsAndMissingOptionalRuntime() throws {
        let fixture = try Fixture()
        let java = try fixture.jdk("1.8.0_492", jreHome: true)
        let node = try fixture.node("22.16.0")
        try fixture.startup(java: java, node: node)
        let resolved = try fixture.resolver.resolve(configuration: .init(), directory: fixture.project)
        XCTAssertEqual(resolved.java.installation?.path, java.path)
        XCTAssertEqual(resolved.java.installation?.version, "1.8.0_492")
        XCTAssertEqual(resolved.node.installation?.path, node.path)
        try fixture.startup(java: nil, node: nil)
        let missing = try fixture.resolver.resolve(configuration: .init(), directory: fixture.project)
        XCTAssertNil(missing.java.installation)
        XCTAssertNil(missing.node.installation)
    }

    func testMissingVersionOrInvalidCustomPathNeverFallsBack() throws {
        let fixture = try Fixture()
        let java = try fixture.jdk("21.0.11")
        try fixture.startup(java: java, node: nil)
        try fixture.file(".java-version", "77\n")
        XCTAssertThrowsError(try fixture.resolver.resolve(configuration: .init(), directory: fixture.project)) {
            XCTAssertTrue($0.localizedDescription.contains("77"))
        }
        let configuration = ServiceRuntimeConfiguration(java: .init(mode: .custom, path: "/missing/jdk"))
        XCTAssertThrowsError(try fixture.resolver.resolve(configuration: configuration, directory: fixture.project)) {
            XCTAssertTrue($0.localizedDescription.contains("/missing/jdk"))
        }
        try fixture.file(".java-version", "$(touch should-not-exist)")
        XCTAssertThrowsError(try fixture.resolver.resolve(configuration: .init(), directory: fixture.project))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("should-not-exist").path))
    }

    func testExplicitPathsOverrideProjectAndShellWithoutChangingOtherServices() throws {
        let fixture = try Fixture()
        let java17 = try fixture.jdk("17.0.12", name: "jdk's $(touch pwned) space")
        let java21 = try fixture.jdk("21.0.11")
        let node18 = try fixture.node("18.20.8", name: "node's $(touch pwned) space")
        let node22 = try fixture.node("22.16.0")
        try fixture.startup(java: java21, node: node22)
        try fixture.file(".java-version", "99")
        try fixture.file(".nvmrc", "99")
        let first = ServiceRuntimeConfiguration(java: .init(mode: .installed, path: java17.path), node: .init(mode: .custom, path: node18.path))
        let second = ServiceRuntimeConfiguration(java: .init(mode: .custom, path: java21.path), node: .init(mode: .installed, path: node22.path))
        let firstResolved = try fixture.resolver.resolve(configuration: first, directory: fixture.project)
        let secondResolved = try fixture.resolver.resolve(configuration: second, directory: fixture.project)
        let command = #"/bin/sh -c 'printf "%s\n" "$JAVA_HOME"; command -v node; printf "%s\n" "$$"'"#
        let originalJavaHome = ProcessInfo.processInfo.environment["JAVA_HOME"]
        for (runtime, java, node) in [(firstResolved, java17, node18), (secondResolved, java21, node22)] {
            let process = ServiceShell.makeProcess(command: command, directory: fixture.project, runtime: runtime)
            process.environment = fixture.resolver.environment
            let output = try RuntimeProbe.run(process, timeout: 3).split(separator: "\n").map(String.init)
            XCTAssertEqual(output, [java.path, node.path, String(process.processIdentifier)])
        }
        XCTAssertEqual(ProcessInfo.processInfo.environment["JAVA_HOME"], originalJavaHome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("pwned").path))
    }

    func testVersionAliasesUseOnlyAlreadyInstalledManagerPaths() throws {
        let fixture = try Fixture()
        let java = try fixture.jdk("21.0.11")
        let node = try fixture.node("22.16.0")
        let versions = fixture.root.appendingPathComponent("jenv/versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: versions.appendingPathComponent("zulu64-21"), withDestinationURL: java)
        try fixture.file(".java-version", "zulu64-21")
        try fixture.file(".nvmrc", "lts/*")
        let nvm = "\nnvm() { [[ $1 == which && $2 == 'lts/*' ]] || return 1; print -r -- \(fixture.quote(node.path)); }\n"
        let rc = fixture.root.appendingPathComponent(".zshrc")
        try (String(contentsOf: rc) + nvm).write(to: rc, atomically: true, encoding: .utf8)
        let result = try fixture.resolver.resolve(configuration: .init(), directory: fixture.project)
        XCTAssertEqual(result.java.installation?.path, java.path)
        XCTAssertEqual(result.node.installation?.path, node.path)
        let catalog = try fixture.resolver.discover(directory: fixture.project)
        XCTAssertEqual(catalog.filter { $0.kind == .java }.count, 1, "jenv symlink aliases must be deduplicated")
    }

    func testNumericMatchingDoesNotConfuseMajorVersions() {
        XCTAssertTrue(ServiceRuntimeResolver.matches(version: "1.8.0_492", request: "8", kind: .java))
        XCTAssertTrue(ServiceRuntimeResolver.matches(version: "18.20.8", request: "v18.20", kind: .node))
        XCTAssertFalse(ServiceRuntimeResolver.matches(version: "18.20.8", request: "8", kind: .node))
        XCTAssertFalse(ServiceRuntimeResolver.matches(version: "21.0.11", request: "17", kind: .java))
        XCTAssertFalse(ServiceRuntimeResolver.matches(version: "22.16.0", request: "lts/*", kind: .node))
    }

    func testProbeTimeoutIsBounded() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        let start = Date()
        XCTAssertThrowsError(try RuntimeProbe.run(process, timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(process.isRunning)
    }

    @MainActor
    func testMissingRuntimeDoesNotReleaseConfiguredPortOrLaunchCommand() async throws {
        let fixture = try Fixture()
        let suite = "StackHubTests.RuntimePort.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let listener = Process()
        listener.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        listener.arguments = ["-rsocket", "-e", "s = TCPServer.new('127.0.0.1', 0); puts s.addr[1]; STDOUT.flush; sleep 30"]
        let pipe = Pipe()
        listener.standardOutput = pipe
        try listener.run()
        defer { if listener.isRunning { listener.terminate(); listener.waitUntilExit() } }
        let port = try XCTUnwrap(Int(String(decoding: pipe.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let store = StackHubStore(defaults: defaults, runtimeResolver: fixture.resolver)
        let runtime = ServiceRuntimeConfiguration(java: .init(mode: .custom, path: "/missing/selected-jdk"))
        XCTAssertTrue(store.addProject(name: "Invalid runtime", directory: fixture.project.path, services: [
            .init(command: "/usr/bin/touch launched", ports: String(port), runtime: runtime)
        ]))
        let service = store.projects[0].services[0]
        store.serviceAction(service)
        for _ in 0..<100 {
            if store.projects[0].services[0].status == .failed { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(store.projects[0].services[0].status, .failed)
        XCTAssertTrue(listener.isRunning, "Runtime validation must happen before port release")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("launched").path))
        XCTAssertTrue(store.serviceLogs[service.id]?.contains("/missing/selected-jdk") == true)
    }

    @MainActor
    func testStopAndRemovalCancelPendingPreparation() async throws {
        let fixture = try Fixture()
        // A shell builtin loop gives a reliably pending probe with no child to orphan.
        try fixture.file(".zshrc", "while true; do :; done", in: fixture.root)
        let suite = "StackHubTests.RuntimeCancel.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StackHubStore(defaults: defaults, runtimeResolver: fixture.resolver)
        XCTAssertTrue(store.addProject(name: "Pending", directory: fixture.project.path, services: [.init(command: "/usr/bin/touch launched")]))
        let project = store.projects[0]
        let service = project.services[0]
        store.serviceAction(service)
        try await Task.sleep(for: .milliseconds(100))
        store.stopAllServices()
        XCTAssertEqual(store.projects[0].services[0].status, .stopped)
        store.serviceAction(service)
        try await Task.sleep(for: .milliseconds(100))
        store.removeProject(project)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("launched").path))
        XCTAssertFalse(store.serviceLogs[service.id]?.contains("timed out") == true)
    }

    @MainActor
    func testRuntimeSettingsSurviveAddEditAndReloadAndLegacyDecode() throws {
        let suite = "StackHubTests.Runtime.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StackHubStore(defaults: defaults)
        let initial = ServiceRuntimeConfiguration(java: .init(mode: .installed, path: "/jdk17"), node: .init(mode: .custom, path: "/node18/bin/node"))
        XCTAssertTrue(store.addProject(name: "Runtime", directory: "/tmp", services: [.init(command: "/bin/true", runtime: initial)]))
        let project = try XCTUnwrap(StackHubStore(defaults: defaults).projects.first)
        XCTAssertEqual(project.services[0].runtime, initial)
        let draft = ProjectDraft(project: project)
        XCTAssertEqual(draft.services[0].runtime, initial)
        draft.services[0].runtime.java = .init()
        XCTAssertTrue(store.updateProject(project, name: project.name, directory: project.directory, services: draft.services))
        let updated = try XCTUnwrap(StackHubStore(defaults: defaults).projects.first)
        XCTAssertEqual(updated.services[0].runtime.java, RuntimeChoice())
        XCTAssertEqual(updated.services[0].runtime.node, initial.node)
        let json = #"{"id":"old","name":"Old","command":"echo old","url":"","status":"stopped"}"#
        XCTAssertEqual(try JSONDecoder().decode(Service.self, from: Data(json.utf8)).runtime, ServiceRuntimeConfiguration())
    }
}
