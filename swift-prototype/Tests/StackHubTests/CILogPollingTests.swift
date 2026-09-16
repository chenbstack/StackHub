import XCTest
@testable import StackHub

@MainActor
final class CILogPollingTests: XCTestCase {
    func testWaitsForRequestsAndStopsAfterFinalFetch() async {
        var count = 0
        var inFlight = 0
        var maximum = 0
        await CILogPolling.run(interval: .milliseconds(1)) {
            inFlight += 1
            maximum = max(maximum, inFlight)
            try? await Task.sleep(for: .milliseconds(10))
            count += 1
            inFlight -= 1
            return count < 3
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(maximum, 1)
    }

    func testClosingDuringWaitStopsFurtherRequests() async {
        var count = 0
        let task = Task {
            await CILogPolling.run(interval: .seconds(30)) {
                count += 1
                return true
            }
        }
        while count == 0 { await Task.yield() }
        task.cancel()
        await task.value
        XCTAssertEqual(count, 1)
    }

    func testClosingDuringRequestDoesNotScheduleAnotherPoll() async {
        var count = 0
        let task = Task {
            await CILogPolling.run(interval: .milliseconds(1)) {
                count += 1
                try? await Task.sleep(for: .seconds(30))
                return true
            }
        }
        while count == 0 { await Task.yield() }
        task.cancel()
        await task.value
        XCTAssertEqual(count, 1)
    }
}
