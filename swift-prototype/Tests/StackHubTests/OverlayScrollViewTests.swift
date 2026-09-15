import AppKit
import SwiftUI
import XCTest
@testable import StackHub

final class OverlayScrollViewTests: XCTestCase {
    @MainActor
    func testSwiftUIContentKeepsFullWidthAfterLegacyStyleReset() async throws {
        let hosting = NSHostingView(rootView:
            OverlayScrollView {
                VStack {
                    ForEach(0..<30) { index in
                        Text("Row \(index)").frame(maxWidth: .infinity).frame(height: 32)
                    }
                }
            }
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 410, height: 400)
        hosting.layoutSubtreeIfNeeded()
        await drainConfigurationQueue()
        hosting.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(firstScrollView(in: hosting))
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.contentView.frame.width, scrollView.bounds.width, accuracy: 0.5)
        XCTAssertTrue(scrollView.hasVerticalScroller)

        // Simulate AppKit/SwiftUI restoring a rail after the first render.
        scrollView.scrollerStyle = .legacy
        await drainConfigurationQueue()
        scrollView.tile()
        XCTAssertEqual(scrollView.scrollerStyle, .overlay)
        XCTAssertEqual(scrollView.contentView.frame.width, scrollView.bounds.width, accuracy: 0.5)

        // An overlay still scrolls the content and remains a native scroller.
        let initialOrigin = scrollView.contentView.bounds.origin
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: initialOrigin.y + 100))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        XCTAssertNotEqual(scrollView.contentView.bounds.origin, initialOrigin)
    }

    @MainActor
    func testProbeAttachesLateAndOnlyConfiguresTheNearestScrollView() async {
        let outer = NSScrollView(frame: NSRect(x: 0, y: 0, width: 410, height: 400))
        let inner = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        outer.scrollerStyle = .legacy
        inner.scrollerStyle = .legacy
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 900))
        let probe = OverlayScrollerProbeView(frame: .zero)
        document.addSubview(probe)
        await drainConfigurationQueue()
        inner.documentView = document
        outer.documentView = inner
        document.layoutSubtreeIfNeeded()
        probe.needsLayout = true
        probe.layoutSubtreeIfNeeded()
        await drainConfigurationQueue()

        XCTAssertEqual(inner.scrollerStyle, .overlay)
        XCTAssertEqual(outer.scrollerStyle, .legacy)
        XCTAssertNil(probe.hitTest(.zero))

        probe.removeFromSuperview()
        inner.scrollerStyle = .legacy
        await drainConfigurationQueue()
        XCTAssertEqual(inner.scrollerStyle, .legacy)
    }

    @MainActor
    private func drainConfigurationQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        return view.subviews.lazy.compactMap { self.firstScrollView(in: $0) }.first
    }
}
