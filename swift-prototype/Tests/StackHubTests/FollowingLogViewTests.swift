import AppKit
import XCTest
@testable import StackHub

@MainActor
final class FollowingLogViewTests: XCTestCase {
    private func lines(_ count: Int) -> String {
        (0..<count).map { "line \($0)" }.joined(separator: "\n")
    }

    func testOpeningAndAppendingFollowBottom() {
        let view = FollowingLogScrollView()
        view.setLog(lines(100))
        XCTAssertTrue(view.isAtBottom)
        XCTAssertGreaterThan(view.contentView.bounds.minY, 0)
        view.setLog(lines(120))
        XCTAssertTrue(view.isAtBottom)
    }

    func testReadingOlderLogsKeepsPositionAndSelectionThenResumesAtBottom() {
        let view = FollowingLogScrollView()
        view.setLog(lines(100))
        view.contentView.scroll(to: NSPoint(x: 0, y: 80))
        view.reflectScrolledClipView(view.contentView)
        view.logTextView.setSelectedRange(NSRange(location: 3, length: 5))
        XCTAssertFalse(view.isAtBottom)
        let offset = view.contentView.bounds.minY
        view.setLog(lines(120))
        XCTAssertEqual(view.contentView.bounds.minY, offset, accuracy: 1)
        XCTAssertEqual(view.logTextView.selectedRange(), NSRange(location: 3, length: 5))
        view.contentView.scroll(to: NSPoint(x: 0, y: view.logTextView.frame.height - view.contentView.bounds.height))
        view.reflectScrolledClipView(view.contentView)
        view.setLog(lines(130))
        XCTAssertTrue(view.isAtBottom)
    }

    func testClearAndSubsequentOutputResumeFollowing() {
        let view = FollowingLogScrollView()
        view.setLog(lines(100))
        view.contentView.scroll(to: .zero)
        view.setLog("No output", isPlaceholder: true)
        view.setLog(lines(120))
        XCTAssertTrue(view.isAtBottom)
    }

    func testANSIColorsAndPlainSelectableTextArePreserved() {
        let view = FollowingLogScrollView()
        view.setLog("\u{1B}[31merror\u{1B}[0m normal")
        XCTAssertEqual(view.logTextView.string, "error normal")
        XCTAssertNotEqual(view.logTextView.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                          view.logTextView.textStorage?.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor)
        XCTAssertTrue(view.logTextView.isSelectable)
        XCTAssertFalse(view.logTextView.isEditable)
    }
}
