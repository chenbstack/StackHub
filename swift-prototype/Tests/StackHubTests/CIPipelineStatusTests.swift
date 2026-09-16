import Foundation
import XCTest
@testable import StackHub

final class CIPipelineStatusTests: XCTestCase {
    @MainActor
    func testSuccessfulLatestRunDoesNotCountHistoricalFailureAfterReload() throws {
        try withStore { store, defaults in
            let project = project("gitlab:office:1")
            store.accessibleCIProjects = [project]
            store.pipelineCache[project.id] = [
                run("old-failure", project: project, time: 100, state: .failed),
                run("latest-success", project: project, time: 200, state: .success)
            ]
            store.ciError = "Partial connection failure"
            store.persistCIState()

            let restored = StackHubStore(defaults: defaults)
            XCTAssertEqual(restored.recentCIActivities.first?.pipeline.id, "latest-success")
            XCTAssertEqual(restored.menuBarPipelineStatus.unreadFailures, 0)
            XCTAssertEqual(restored.pipelineCache[project.id]?.count, 2, "Keep history available")
            XCTAssertEqual(try XCTUnwrap(restored.pipelineCache[project.id]?.first).state, .failed)
        }
    }

    @MainActor
    func testOnlyDashboardProjectsCountAndFollowedCardsAreNotCountedTwice() {
        withStore { store, _ in
            let indexed = project("gitlab:online:1")
            let followed = project("gitlab:offline:2")
            let orphan = project("gitlab:removed:3")
            store.accessibleCIProjects = [indexed]
            store.ciProjects = [indexed, followed].map { project in
                CIMonitoredProject(id: project.id, name: project.name, provider: project.provider,
                                   repository: project.repository, branch: "main", instanceName: project.instanceName)
            }
            for project in [indexed, followed, orphan] {
                store.pipelineCache[project.id] = [run("failed", project: project, time: 100, state: .failed)]
            }
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 2)
        }
    }

    @MainActor
    func testLatestFailureIsAcknowledgedOnEveryPanelOpenAndPersists() {
        withStore { store, defaults in
            let project = project("gitlab:office:1")
            store.accessibleCIProjects = [project]
            store.pipelineCache[project.id] = [run("failure-1", project: project, time: 100, state: .failed)]
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 1)
            store.setPanelVisible(true)
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 0)
            store.persistCIState()
            XCTAssertEqual(StackHubStore(defaults: defaults).menuBarPipelineStatus.unreadFailures, 0)

            store.setPanelVisible(false)
            store.pipelineCache[project.id]?.append(run("failure-2", project: project, time: 200, state: .failed))
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 1)
            store.setPanelVisible(true)
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 0)
        }
    }

    @MainActor
    func testMountedCIViewOnlyAcknowledgesRefreshesWhenPanelAndActivityAreVisible() {
        withStore { store, _ in
            let project = project("gitlab:office:1")
            store.accessibleCIProjects = [project]
            store.setCIActivityVisible(true)
            store.setPanelVisible(true)
            store.pipelineCache[project.id] = [run("failure-1", project: project, time: 100, state: .failed)]
            store.persistCIState()
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 0, "A delayed result is already visible")

            // Hiding the reused panel does not unmount its SwiftUI content.
            store.setPanelVisible(false)
            store.pipelineCache[project.id]?.append(run("failure-2", project: project, time: 200, state: .failed))
            store.persistCIState()
            store.setCIActivityVisible(false)
            store.setCIActivityVisible(true)
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 1, "Hidden views must not consume new failures")

            store.setPanelVisible(true)
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 0)
            store.setCIActivityVisible(false)
            store.pipelineCache[project.id]?.append(run("failure-3", project: project, time: 300, state: .failed))
            store.persistCIState()
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 1, "Another panel page cannot see the new failure")
            store.setCIActivityVisible(true)
            XCTAssertEqual(store.menuBarPipelineStatus.unreadFailures, 0)
        }
    }

    @MainActor
    func testLatestRunningStatusUsesTheSameScopeAsFailureStatus() {
        withStore { store, _ in
            let project = project("gitlab:office:1")
            store.accessibleCIProjects = [project]
            store.pipelineCache[project.id] = [
                run("old-failure", project: project, time: 100, state: .failed),
                run("running", project: project, time: 200, state: .running)
            ]
            XCTAssertEqual(store.menuBarPipelineStatus, CIPipelineStatusCounts(running: 1, unreadFailures: 0))
            store.pipelineCache[project.id]?.append(run("success", project: project, time: 300, state: .success))
            XCTAssertFalse(store.menuBarPipelineStatus.hasVisibleCount)
        }
    }

    @MainActor
    private func withStore(_ body: (StackHubStore, UserDefaults) throws -> Void) rethrows {
        let suiteName = "StackHub.PipelineStatusTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(StackHubStore(defaults: defaults), defaults)
    }

    private func project(_ id: String) -> CIAccessibleProject {
        CIAccessibleProject(id: id, name: "Example", provider: "GitLab CI", repository: "team/example",
                            branch: "main", instanceName: "Example")
    }

    private func run(_ id: String, project: CIAccessibleProject, time: TimeInterval, state: PipelineState) -> Pipeline {
        Pipeline(id: id, projectID: project.id, provider: project.provider, repository: project.repository,
                 branch: "main", commit: "test", duration: "1 sec", state: state, stages: [],
                 updatedAt: Date(timeIntervalSince1970: time), webURL: nil)
    }
}
