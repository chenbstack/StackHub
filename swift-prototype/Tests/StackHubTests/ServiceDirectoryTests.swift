import Foundation
import XCTest
@testable import StackHub

final class ServiceDirectoryTests: XCTestCase {
    func testLegacyProjectWithoutServiceDirectoryStillLoads() throws {
        let json = """
        [{"id":"legacy","name":"Existing project","initial":"E","serviceCount":1,
          "issue":false,"isExpanded":true,"directory":"/tmp/existing-project",
          "services":[{"id":"api","name":"API","command":"npm run dev","url":"","status":"stopped"}]}]
        """
        let project = try XCTUnwrap(JSONDecoder().decode([Project].self, from: Data(json.utf8)).first)

        XCTAssertNil(project.services[0].directory)
        XCTAssertEqual(WorkingDirectory.resolve(project.services[0].directory, projectDirectory: project.directory).path,
                       "/tmp/existing-project")
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
    func testAddEditReloadAndClearServiceDirectories() throws {
        let suite = "StackHubTests.ServiceDirectories.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = StackHubStore(defaults: defaults)

        XCTAssertTrue(store.addProject(name: "Web app", directory: "/tmp/project", services: [
            ProjectServiceDraft(name: "Backend", command: "/bin/pwd", directory: " backend "),
            ProjectServiceDraft(name: "Frontend", command: "/bin/pwd", directory: "/tmp/前端 app"),
            ProjectServiceDraft(name: "Worker", command: "/bin/pwd")
        ]))
        let saved = try XCTUnwrap(StackHubStore(defaults: defaults).projects.first)
        XCTAssertEqual(saved.services.map(\.directory), ["backend", "/tmp/前端 app", nil])

        let draft = ProjectDraft(project: saved)
        XCTAssertEqual(draft.services.map(\.directory), ["backend", "/tmp/前端 app", ""])
        draft.directory = "/tmp/moved project"
        draft.services[0].directory = " ../backend "
        draft.services[1].directory = " \n "
        draft.services[2].directory = "/tmp/external worker"
        XCTAssertTrue(store.updateProject(saved, name: draft.name, directory: draft.directory, services: draft.services))

        let updated = try XCTUnwrap(StackHubStore(defaults: defaults).projects.first)
        XCTAssertEqual(updated.services.map(\.id), saved.services.map(\.id))
        XCTAssertEqual(updated.services.map(\.directory), ["../backend", nil, "/tmp/external worker"])
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
        XCTAssertEqual(store.projects[0].services[0].status, .running)

        store.stopAllServices()
        XCTAssertEqual(store.projects[0].services[0].status, .stopped)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(StackHubStore(defaults: defaults).projects[0].services[0].status, .stopped)
    }
}
