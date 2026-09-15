import Foundation
import XCTest
@testable import StackHub

final class ServiceDirectoryTests: XCTestCase {
    func testPanelHeightOnlyShrinksOnOpenWhenItExceedsScreenNinetyPercent() {
        XCTAssertEqual(PanelWindowSizing.openingHeight(640, visibleScreenHeight: 900), 640)
        XCTAssertEqual(PanelWindowSizing.openingHeight(1_000, visibleScreenHeight: 900), 810)
        XCTAssertEqual(PanelWindowSizing.openingHeight(1_000, visibleScreenHeight: 0), 1_000)
    }

    func testStartupEvidencePrioritizesErrorsOverReadySignals() {
        XCTAssertEqual(ServiceStartupEvidence.classify(log: "Server listening on http://127.0.0.1:3000"), .ready)
        XCTAssertEqual(ServiceStartupEvidence.classify(log: "启动完成\nERROR: unable to bind port"), .warning)
        XCTAssertNil(ServiceStartupEvidence.classify(log: "loading configuration"))
    }

    func testProjectRuntimeStateDoesNotShowStoppedServicesAsReady() {
        let stopped = Service(id: "stopped", name: "Stopped", command: "", url: "", status: .stopped)
        let running = Service(id: "running", name: "Running", command: "", url: "", status: .running)
        let failed = Service(id: "failed", name: "Failed", command: "", url: "", status: .failed)

        XCTAssertEqual(Project(id: "a", name: "Stopped", initial: "S", serviceCount: 1, issue: false, isExpanded: false, services: [stopped], directory: "/tmp").runtimeState, .stopped)
        XCTAssertEqual(Project(id: "b", name: "Partial", initial: "P", serviceCount: 2, issue: false, isExpanded: false, services: [running, stopped], directory: "/tmp").runtimeState, .partial)
        XCTAssertEqual(Project(id: "c", name: "Ready", initial: "R", serviceCount: 1, issue: false, isExpanded: false, services: [running], directory: "/tmp").runtimeState, .ready)
        XCTAssertEqual(Project(id: "d", name: "Issue", initial: "I", serviceCount: 1, issue: false, isExpanded: false, services: [failed], directory: "/tmp").runtimeState, .issue)
    }

    func testANSILogRendererPreservesColorSegmentsAndRemovesControlCodes() {
        let source = "plain \u{001B}[36mcyan\u{001B}[39m \u{001B}[38;2;255;100;0morange\u{001B}[0m"
        XCTAssertEqual(ANSILogRenderer.segments(from: source), [
            ANSILogSegment(text: "plain ", foreground: nil),
            ANSILogSegment(text: "cyan", foreground: .standard(6)),
            ANSILogSegment(text: " ", foreground: nil),
            ANSILogSegment(text: "orange", foreground: .rgb(255, 100, 0))
        ])
        XCTAssertEqual(String(ANSILogRenderer.attributedString(from: source).characters), "plain cyan orange")
    }

    func testPortConfigurationValidationAndPIDParsing() {
        XCTAssertEqual(ServicePortGuard.configuredPorts(from: " 3000, 5173 "), [3000, 5173])
        XCTAssertEqual(ServicePortGuard.configuredPorts(from: " \n "), [])
        XCTAssertNil(ServicePortGuard.configuredPorts(from: "0, 5173"))
        XCTAssertNil(ServicePortGuard.configuredPorts(from: "3000,,5173"))
        XCTAssertNil(ServicePortGuard.configuredPorts(from: "3000, 3000"))
        XCTAssertTrue(ServicePortGuard.hasValidConfiguration("3000,5173"))
        XCTAssertFalse(ServicePortGuard.hasValidConfiguration("three thousand"))
        XCTAssertEqual(ServicePortGuard.listenerProcessIDs(from: "42\n17\n42\ninvalid\n"), [17, 42])
    }

    func testReleaseConfiguredPortsTerminatesEveryListener() throws {
        let first = try startTemporaryListener()
        let second = try startTemporaryListener()
        defer {
            for process in [first.process, second.process] where process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let released = try ServicePortGuard.release(ports: [first.port, second.port])

        XCTAssertEqual(released[first.port], [Int32(first.process.processIdentifier)])
        XCTAssertEqual(released[second.port], [Int32(second.process.processIdentifier)])
        XCTAssertFalse(first.process.isRunning)
        XCTAssertFalse(second.process.isRunning)
    }

    private func startTemporaryListener() throws -> (process: Process, port: Int) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [
            "-rsocket",
            "-e",
            "server = TCPServer.new('127.0.0.1', 0); puts server.addr[1]; STDOUT.flush; sleep 30"
        ]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let portOutput = output.fileHandleForReading.availableData
        let port = Int(String(decoding: portOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        return (process, try XCTUnwrap(port))
    }

    func testLegacyProjectWithoutServiceDirectoryStillLoads() throws {
        let json = """
        [{"id":"legacy","name":"Existing project","initial":"E","serviceCount":1,
          "issue":false,"isExpanded":true,"directory":"/tmp/existing-project",
          "services":[{"id":"api","name":"API","command":"npm run dev","url":"","status":"stopped"}]}]
        """
        let project = try XCTUnwrap(JSONDecoder().decode([Project].self, from: Data(json.utf8)).first)

        XCTAssertNil(project.services[0].directory)
        XCTAssertEqual(project.services[0].ports, [])
        XCTAssertEqual(WorkingDirectory.resolve(project.services[0].directory, projectDirectory: project.directory).path,
                       "/tmp/existing-project")
    }

    func testLegacySinglePortMigratesToPortList() throws {
        let json = """
        [{"id":"legacy","name":"Existing project","initial":"E","serviceCount":1,
          "issue":false,"isExpanded":true,"directory":"/tmp/existing-project",
          "services":[{"id":"api","name":"API","command":"npm run dev","url":"","status":"stopped","port":3000}]}]
        """
        let project = try XCTUnwrap(JSONDecoder().decode([Project].self, from: Data(json.utf8)).first)

        XCTAssertEqual(project.services[0].ports, [3000])
        let encoded = try JSONEncoder().encode(project.services[0])
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"ports\":[3000]"))
    }

    func testRelativeAbsoluteAndHomePathsResolveAgainstProjectDirectory() {
        let project = "/tmp/project root"
        XCTAssertEqual(WorkingDirectory.resolve("frontend", projectDirectory: project).path, "/tmp/project root/frontend")
        XCTAssertEqual(WorkingDirectory.resolve("../backend", projectDirectory: project).path, "/tmp/backend")
        XCTAssertEqual(WorkingDirectory.resolve("./前端 app", projectDirectory: project).path, "/tmp/project root/前端 app")
        XCTAssertEqual(WorkingDirectory.resolve("/tmp/separate backend", projectDirectory: project).path, "/tmp/separate backend")
        XCTAssertEqual(WorkingDirectory.resolve("~/Code/api", projectDirectory: project).path,
                       ("~/Code/api" as NSString).expandingTildeInPath)
        XCTAssertEqual(WorkingDirectory.resolve(" \n ", projectDirectory: project).path, project)
        XCTAssertEqual(WorkingDirectory.resolve(".", projectDirectory: "~/Code/project").path,
                       ("~/Code/project" as NSString).expandingTildeInPath)
    }

    @MainActor
    func testProjectRejectsInvalidConfiguredPort() throws {
        let suite = "StackHubTests.InvalidPort.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StackHubStore(defaults: defaults)

        XCTAssertFalse(store.addProject(name: "Invalid port", directory: "/tmp", services: [
            ProjectServiceDraft(name: "API", command: "/bin/sleep 1", ports: "70000, 5173")
        ]))
        XCTAssertEqual(store.toast, "服务端口须为 1–65535 的逗号分隔列表，或留空")
        XCTAssertTrue(store.projects.isEmpty)
    }

    @MainActor
    func testAddEditReloadAndClearServiceDirectories() throws {
        let suite = "StackHubTests.ServiceDirectories.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StackHubStore(defaults: defaults)

        XCTAssertTrue(store.addProject(name: "Web app", directory: "/tmp/project", services: [
            ProjectServiceDraft(name: "Backend", command: "/bin/pwd", directory: " backend "),
            ProjectServiceDraft(name: "Frontend", command: "/bin/pwd", directory: "/tmp/前端 app"),
            ProjectServiceDraft(name: "Worker", command: "/bin/pwd", ports: "3100, 5173")
        ]))
        let saved = try XCTUnwrap(StackHubStore(defaults: defaults).projects.first)
        XCTAssertEqual(saved.services.map(\.directory), ["backend", "/tmp/前端 app", nil])
        XCTAssertEqual(saved.services.map(\.ports), [[], [], [3100, 5173]])

        let draft = ProjectDraft(project: saved)
        XCTAssertEqual(draft.services.map(\.directory), ["backend", "/tmp/前端 app", ""])
        XCTAssertEqual(draft.services.map(\.ports), ["", "", "3100, 5173"])
        draft.directory = "/tmp/moved project"
        draft.services[0].directory = " ../backend "
        draft.services[1].directory = " \n "
        draft.services[2].directory = "/tmp/external worker"
        XCTAssertTrue(store.updateProject(saved, name: draft.name, directory: draft.directory, services: draft.services))

        let updated = try XCTUnwrap(StackHubStore(defaults: defaults).projects.first)
        XCTAssertEqual(updated.services.map(\.id), saved.services.map(\.id))
        XCTAssertEqual(updated.services.map(\.directory), ["../backend", nil, "/tmp/external worker"])
        XCTAssertEqual(updated.services.map(\.ports), [[], [], [3100, 5173]])
        XCTAssertEqual(WorkingDirectory.resolve(updated.services[0].directory, projectDirectory: updated.directory).path, "/tmp/backend")
        XCTAssertEqual(WorkingDirectory.resolve(updated.services[1].directory, projectDirectory: updated.directory).path, "/tmp/moved project")
        XCTAssertEqual(ProjectDraft(project: updated).services[1].directory, "")
    }

    @MainActor
    func testActualServicesStartInTheirOwnDirectories() async throws {
        let suite = "StackHubTests.ServiceLaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-\(UUID().uuidString)", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("项目 root", isDirectory: true)
        let frontend = projectDirectory.appendingPathComponent("前端 app", isDirectory: true)
        let backend = root.appendingPathComponent("独立 backend", isDirectory: true)
        try FileManager.default.createDirectory(at: frontend, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backend, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = StackHubStore(defaults: defaults)
        // Each real child process writes its actual cwd using the same relative
        // output filename. Distinct files prove the launch directory is applied.
        let command = "/bin/sh -c 'pwd -P > .stackhub-cwd'"
        XCTAssertTrue(store.addProject(name: "Separate services", directory: projectDirectory.path, services: [
            ProjectServiceDraft(name: "Frontend", command: command, directory: "前端 app"),
            ProjectServiceDraft(name: "Backend", command: command, directory: backend.path),
            ProjectServiceDraft(name: "Inherited", command: command)
        ]))
        let reloadedStore = StackHubStore(defaults: defaults)
        let project = try XCTUnwrap(reloadedStore.projects.first)
        defer { reloadedStore.projectAction(project, action: "停止") }
        reloadedStore.projectAction(project, action: "启动")
        let directories = [frontend, backend, projectDirectory]
        let outputs = directories.map { $0.appendingPathComponent(".stackhub-cwd") }
        for _ in 0..<100 {
            if outputs.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }),
               reloadedStore.projects[0].services.allSatisfy({ $0.status == .stopped }) {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertNil(reloadedStore.toast)
        XCTAssertTrue(reloadedStore.projects[0].services.allSatisfy { $0.status == .stopped })
        for (output, directory) in zip(outputs, directories) {
            let actual = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            // macOS exposes /var/folders through /private/var/folders to the
            // child process, while URL construction may retain the symlink.
            let expected = directory.path.replacingOccurrences(of: "/var/folders", with: "/private/var/folders")
            XCTAssertEqual(actual, expected)
        }
    }

    @MainActor
    func testInvalidServiceDirectoryDoesNotFallBackToProject() throws {
        let suite = "StackHubTests.InvalidDirectory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("ordinary file".utf8).write(to: root.appendingPathComponent("file.txt"))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = StackHubStore(defaults: defaults)
        XCTAssertTrue(store.addProject(name: "Invalid paths", directory: root.path, services: [
            ProjectServiceDraft(name: "Missing", command: "/bin/pwd", directory: "missing"),
            ProjectServiceDraft(name: "File", command: "/bin/pwd", directory: "file.txt")
        ]))
        let project = try XCTUnwrap(store.projects.first)
        for service in project.services {
            store.serviceAction(service)
            XCTAssertEqual(store.projects[0].services.first { $0.id == service.id }?.status, .failed)
            XCTAssertTrue(store.toast?.contains(service.name) == true)
            XCTAssertTrue(store.toast?.contains(root.appendingPathComponent(service.directory!).path) == true)
            XCTAssertNil(store.serviceLogs[service.id])
        }
    }

    @MainActor
    func testServiceLogsCaptureOutputAndCanBeCleared() async throws {
        let suite = "StackHubTests.ServiceLogs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = StackHubStore(defaults: defaults)
        XCTAssertTrue(store.addProject(name: "Logs", directory: directory.path, services: [
            ProjectServiceDraft(name: "API", command: "/bin/sh -c 'printf stdout; printf stderr >&2'")
        ]))
        let service = try XCTUnwrap(store.projects.first?.services.first)
        store.serviceAction(service)

        for _ in 0..<100 {
            if (store.serviceLogs[service.id] ?? "").contains("stdout"),
               (store.serviceLogs[service.id] ?? "").contains("stderr") {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(store.serviceLogs[service.id]?.contains("stdout") == true)
        XCTAssertTrue(store.serviceLogs[service.id]?.contains("stderr") == true)

        store.clearServiceLog(service)
        XCTAssertEqual(store.serviceLogs[service.id], "")
    }

    @MainActor
    func testServiceLogEvidenceControlsReadyAndWarningStates() async throws {
        let suite = "StackHubTests.ServiceReadiness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = StackHubStore(defaults: defaults)
        XCTAssertTrue(store.addProject(name: "Readiness", directory: directory.path, services: [
            ProjectServiceDraft(name: "Ready", command: "/bin/sh -c 'echo \"Server listening on http://127.0.0.1:3000\"; sleep 60'"),
            ProjectServiceDraft(name: "Warning", command: "/bin/sh -c 'echo \"ERROR: unable to bind port\" >&2; sleep 60'")
        ]))
        let services = store.projects[0].services
        for service in services { store.serviceAction(service) }

        for _ in 0..<100 {
            let states = store.projects[0].services.map(\.status)
            if states.contains(.running), states.contains(.warning) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(store.projects[0].services.first { $0.name == "Ready" }?.status, .running)
        XCTAssertEqual(store.projects[0].services.first { $0.name == "Warning" }?.status, .warning)
        store.stopAllServices()
    }

    @MainActor
    func testRestartStopsBeforeStartingReplacement() async throws {
        let suite = "StackHubTests.Restart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = StackHubStore(defaults: defaults)
        XCTAssertTrue(store.addProject(name: "Restart", directory: directory.path, services: [
            ProjectServiceDraft(name: "Server", command: "/bin/sh -c 'echo ready; sleep 60'")
        ]))
        let service = try XCTUnwrap(store.projects.first?.services.first)
        store.serviceAction(service)
        for _ in 0..<100 {
            if store.projects[0].services[0].status == .running { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(store.projects[0].services[0].status, .running)

        store.restartService(service)
        for _ in 0..<100 {
            if store.projects[0].services[0].status == .running,
               (store.serviceLogs[service.id] ?? "").contains("ready") { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(store.projects[0].services[0].status, .running)
        store.stopAllServices()
    }

    @MainActor
    func testToastAutomaticallyDismissesAndResetsItsTimer() async throws {
        let suite = "StackHubTests.Toast.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StackHubStore(defaults: defaults)

        store.toast = "第一条提示"
        try await Task.sleep(nanoseconds: 700_000_000)
        store.toast = "第二条提示"
        try await Task.sleep(nanoseconds: 950_000_000)
        XCTAssertEqual(store.toast, "第二条提示")
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(store.toast)
    }

    @MainActor
    func testStoppingAllServicesClearsManagedProcessesBeforeExit() async throws {
        let suite = "StackHubTests.StopAll.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StackHub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = StackHubStore(defaults: defaults)
        XCTAssertTrue(store.addProject(name: "Long running", directory: directory.path, services: [
            ProjectServiceDraft(name: "Server", command: "/bin/sleep 60")
        ]))
        let service = try XCTUnwrap(store.projects.first?.services.first)
        store.serviceAction(service)
        XCTAssertEqual(store.projects[0].services[0].status, .starting)

        store.stopAllServices()
        XCTAssertEqual(store.projects[0].services[0].status, .stopped)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(StackHubStore(defaults: defaults).projects[0].services[0].status, .stopped)
    }
}
