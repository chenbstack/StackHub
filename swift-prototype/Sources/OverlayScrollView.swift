import AppKit
import SwiftUI

/// Native overlay indicators on either axis, without a reserved rail.
struct OverlayScrollView<Content: View>: View {
    var axes: Axis.Set = .vertical
    var showsIndicators = true
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content.background(OverlayScrollerConfigurator(axes: axes, showsIndicators: showsIndicators))
        }
    }
}

private struct OverlayScrollerConfigurator: NSViewRepresentable {
    let axes: Axis.Set
    let showsIndicators: Bool
    func makeNSView(context: Context) -> OverlayScrollerProbeView {
        let probe = OverlayScrollerProbeView(frame: .zero)
        probe.axes = axes
        probe.showsIndicators = showsIndicators
        return probe
    }

    func updateNSView(_ nsView: OverlayScrollerProbeView, context: Context) {
        nsView.axes = axes
        nsView.showsIndicators = showsIndicators
        nsView.scheduleConfiguration()
    }
}

final class OverlayScrollerProbeView: NSView {
    var axes: Axis.Set = .vertical
    var showsIndicators = true
    private weak var scrollView: NSScrollView?
    private var styleObservation: NSKeyValueObservation?
    private var configurationScheduled = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureEnclosingScrollView()
        scheduleConfiguration()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureEnclosingScrollView()
        scheduleConfiguration()
    }

    override func layout() {
        super.layout()
        configureEnclosingScrollView()
    }

    // A SwiftUI background must not intercept card clicks or scroller drags.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func scheduleConfiguration() {
        guard !configurationScheduled else { return }
        configurationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configurationScheduled = false
            self.configureEnclosingScrollView()
        }
    }

    private func configureEnclosingScrollView() {
        // The probe lives in the document content. Looking only at creation
        // time can miss the NSScrollView, which SwiftUI attaches later.
        let enclosing = enclosingScrollView
        if scrollView !== enclosing {
            styleObservation = nil
            scrollView = enclosing
            // AppKit can restore the system style when pointing devices or
            // preferences change. Reapply after that update has completed.
            styleObservation = enclosing?.observe(\.scrollerStyle, options: [.new]) { [weak self] _, change in
                if change.newValue != .overlay { self?.scheduleConfiguration() }
            }
        }
        guard let enclosing else { return }
        if enclosing.scrollerStyle != .overlay { enclosing.scrollerStyle = .overlay }
        if !enclosing.autohidesScrollers { enclosing.autohidesScrollers = true }
        let horizontal = showsIndicators && axes.contains(.horizontal)
        let vertical = showsIndicators && axes.contains(.vertical)
        if enclosing.hasHorizontalScroller != horizontal { enclosing.hasHorizontalScroller = horizontal }
        if enclosing.hasVerticalScroller != vertical { enclosing.hasVerticalScroller = vertical }
        if enclosing.drawsBackground { enclosing.drawsBackground = false }
        if enclosing.scrollerKnobStyle != .light { enclosing.scrollerKnobStyle = .light }
    }
}
