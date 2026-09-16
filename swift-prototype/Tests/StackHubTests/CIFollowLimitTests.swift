import Foundation
import XCTest
@testable import StackHub

final class CIFollowLimitTests: XCTestCase {
    @MainActor
    func testFiveProjectLimitIsSharedAcrossProvidersAndPersistsAfterRestart() {
        withStore { store, defaults in
            let projects = (1...6).map { index in
                CIAccessibleProject(
                    id: index.isMultiple(of: 2) ? "github:owner/project\(index)" : "gitlab:instance\(index):1",
                    name: "Project \(index)", provider: index.isMultiple(of: 2) ? "GitHub Actions" : "GitLab CI",
                    repository: "owner/project\(index)", branch: "main", isOwnedByCurrentUser: true
                )
            }
            store.accessibleCIProjects = projects
            for project in projects { store.followProject(project.id) }
            XCTAssertEqual(store.ciProjects.map(\.id), projects.prefix(5).map(\.id))
            XCTAssertTrue(store.hasReachedCIFollowLimit)
            XCTAssertEqual(store.toast, store.ciFollowLimitMessage)
            XCTAssertEqual(store.selectedCIProjectID, projects[4].id)

            let restored = StackHubStore(defaults: defaults)
            restored.followProject(projects[5].id)
            XCTAssertEqual(restored.ciProjects.count, 5)
            restored.followProject(projects[0].id)
            XCTAssertEqual(restored.ciProjects.count, 5, "A repeated click must not consume another slot")

            restored.unfollowProject(projects[0].id)
            XCTAssertFalse(restored.hasReachedCIFollowLimit)
            restored.followProject(projects[5].id)
            XCTAssertEqual(restored.ciProjects.count, 5)
            XCTAssertTrue(restored.isFollowing(projects[5].id))
            XCTAssertFalse(restored.isFollowing(projects[0].id))
            XCTAssertEqual(StackHubStore(defaults: defaults).ciProjects.map(\.id), restored.ciProjects.map(\.id))
        }
    }

    @MainActor
    func testExistingOverLimitPreferencesArePreservedButCannotGrow() {
        withStore { store, defaults in
            let projects = (1...7).map { index in
                CIAccessibleProject(id: "gitlab:one:\(index)", name: "Project \(index)", provider: "GitLab CI",
                                    repository: "team/project\(index)", branch: "main")
            }
            store.accessibleCIProjects = projects
            store.ciProjects = projects.prefix(6).map {
                CIMonitoredProject(id: $0.id, name: $0.name, provider: $0.provider,
                                   repository: $0.repository, branch: $0.branch, instanceName: nil)
            }
            store.persistCIState()
            let restored = StackHubStore(defaults: defaults)
            XCTAssertEqual(restored.ciProjects.count, 6)
            restored.followProject(projects[6].id)
            XCTAssertEqual(restored.ciProjects.count, 6)
            restored.unfollowProject(projects[0].id)
            XCTAssertTrue(restored.hasReachedCIFollowLimit)
            restored.unfollowProject(projects[1].id)
            restored.followProject(projects[6].id)
            XCTAssertEqual(restored.ciProjects.count, 5)
            XCTAssertTrue(restored.isFollowing(projects[6].id))
        }
    }

    @MainActor
    private func withStore(_ body: (StackHubStore, UserDefaults) -> Void) {
        let name = "StackHub.FollowLimitTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(StackHubStore(defaults: defaults), defaults)
    }
}
