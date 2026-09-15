import AppKit
import XCTest
@testable import StackHub

final class PanelDismissalPolicyTests: XCTestCase {
    @MainActor
    func testClicksInPanelAndItsNestedChildWindowsKeepPanelOpen() async {
        let panel = makeWindow()
        let child = makeWindow()
        let nested = makeWindow()
        child.parent = panel
        nested.parent = child

        for clickedWindow in [panel, child, nested] {
            XCTAssertFalse(PanelDismissalPolicy.shouldDismiss(panel: panel, clickedWindow: clickedWindow, modalWindow: nil))
        }
    }

    @MainActor
    func testSheetConfirmationAndOutsideClicksKeepHostVisibleUntilDismissal() async {
        let panel = makeWindow()
        let sheet = makeWindow()
        let unrelated = makeWindow()
        panel.testAttachedSheet = sheet
        sheet.testSheetParent = panel

        for clickedWindow: NSWindow? in [sheet, unrelated, nil] {
            XCTAssertFalse(PanelDismissalPolicy.shouldDismiss(panel: panel, clickedWindow: clickedWindow, modalWindow: nil))
        }
        XCTAssertTrue(PanelDismissalPolicy.isPresentingModal(panel: panel, modalWindow: nil))

        // Ending a sheet must restore ordinary outside-click dismissal.
        panel.testAttachedSheet = nil
        sheet.testSheetParent = nil
        XCTAssertFalse(PanelDismissalPolicy.isPresentingModal(panel: panel, modalWindow: nil))
        XCTAssertTrue(PanelDismissalPolicy.shouldDismiss(panel: panel, clickedWindow: unrelated, modalWindow: nil))
        XCTAssertTrue(PanelDismissalPolicy.shouldDismiss(panel: panel, clickedWindow: nil, modalWindow: nil))
    }

    @MainActor
    func testSheetParentIsRecognizedEvenWhenHostHasNoAttachedSheet() async {
        let panel = makeWindow()
        let sheet = makeWindow()
        sheet.testSheetParent = panel
        XCTAssertFalse(PanelDismissalPolicy.shouldDismiss(panel: panel, clickedWindow: sheet, modalWindow: nil))
    }

    @MainActor
    func testAppModalDialogProtectsHostWithoutAnAttachedSheet() async {
        let panel = makeWindow()
        let alert = makeWindow()
        XCTAssertFalse(PanelDismissalPolicy.shouldDismiss(panel: panel, clickedWindow: alert, modalWindow: alert))
        XCTAssertFalse(PanelDismissalPolicy.shouldDismiss(panel: panel, clickedWindow: nil, modalWindow: alert))
        XCTAssertTrue(PanelDismissalPolicy.isPresentingModal(panel: panel, modalWindow: alert))
    }

    @MainActor
    private func makeWindow() -> TestWindow {
        _ = NSApplication.shared
        return TestWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
    }
}

/// Model AppKit's window relationships without displaying windows in unit tests.
private final class TestWindow: NSWindow {
    weak var testSheetParent: NSWindow?
    weak var testAttachedSheet: NSWindow?
    override var sheetParent: NSWindow? { testSheetParent }
    override var attachedSheet: NSWindow? { testAttachedSheet }
}
