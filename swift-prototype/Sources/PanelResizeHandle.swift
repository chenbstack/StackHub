import SwiftUI
import AppKit

enum PanelWindowSizing {
    static let minimumHeight: CGFloat = 500

    /// The persisted panel size is intentionally not capped. It is only
    /// reduced when opening on a screen that can no longer contain it, such
    /// as after changing display resolution or moving to another display.
    static func openingHeight(_ requestedHeight: CGFloat, visibleScreenHeight: CGFloat) -> CGFloat {
        guard visibleScreenHeight > 0 else { return requestedHeight }
        return min(requestedHeight, visibleScreenHeight * 0.9)
    }
}

/// A native AppKit tracking view gives the menu-bar window a real bottom-edge
/// resize affordance.  The top edge remains anchored while the pointer moves,
/// which feels like resizing a popover instead of stretching its contents.
struct PanelResizeHandle: NSViewRepresentable {
    @Binding var height: Double

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> ResizeTrackingView {
        let view = ResizeTrackingView()
        view.onHeightChange = { newHeight in
            context.coordinator.height.wrappedValue = newHeight
        }
        return view
    }

    func updateNSView(_ nsView: ResizeTrackingView, context: Context) {
        nsView.currentHeight = height
        nsView.needsDisplay = true
    }

    final class Coordinator {
        var height: Binding<Double>
        init(height: Binding<Double>) { self.height = height }
    }
}

final class ResizeTrackingView: NSView {
    var onHeightChange: ((Double) -> Void)?
    var currentHeight: Double = 640
    private var dragStartHeight: CGFloat?
    private var dragStartMouseY: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let grip = NSRect(x: (bounds.width - 34) / 2, y: (bounds.height - 3) / 2, width: 34, height: 3)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartHeight = window.frame.height
        dragStartMouseY = NSEvent.mouseLocation.y
        NSCursor.resizeUpDown.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let startHeight = dragStartHeight, let startMouseY = dragStartMouseY else { return }
        let delta = startMouseY - NSEvent.mouseLocation.y
        // Let people size the panel as tall as they need. A display-aware
        // safety clamp runs only when it is opened or its screen changes.
        let newHeight = max(startHeight + delta, PanelWindowSizing.minimumHeight)
        var frame = window.frame
        let top = frame.maxY
        frame.size.height = newHeight
        frame.origin.y = top - newHeight
        window.setFrame(frame, display: true)
        onHeightChange?(Double(newHeight))
    }

    override func mouseUp(with event: NSEvent) {
        dragStartHeight = nil
        dragStartMouseY = nil
        NSCursor.pop()
    }
}

/// MenuBarExtra's hosting panel can retain an opaque AppKit background around
/// a clipped SwiftUI surface.  Clearing it removes the light halo/white border
/// while keeping the system's panel positioning and shadow behavior intact.
struct PanelWindowTuner: NSViewRepresentable {
    @Binding var height: Double

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> PanelWindowTuningView {
        let view = PanelWindowTuningView(frame: .zero)
        view.onHeightAdjusted = { newHeight in
            context.coordinator.height.wrappedValue = newHeight
        }
        return view
    }

    func updateNSView(_ nsView: PanelWindowTuningView, context: Context) {
        nsView.onHeightAdjusted = { newHeight in
            context.coordinator.height.wrappedValue = newHeight
        }
        nsView.configureWindow()
    }

    final class Coordinator {
        var height: Binding<Double>
        init(height: Binding<Double>) { self.height = height }
    }
}

final class PanelWindowTuningView: NSView {
    var onHeightAdjusted: ((Double) -> Void)?
    private weak var observedWindow: NSWindow?
    private var screenObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeScreenChanges(for: window)
        configureWindow()
        // MenuBarExtra may apply its panel style one run-loop later; applying
        // once more after attachment lets us measure the actual target screen.
        DispatchQueue.main.async { [weak self] in self?.configureWindow() }
    }

    deinit { removeScreenObservers() }

    func configureWindow() {
        tunePanelWindow(window, onHeightAdjusted: onHeightAdjusted)
    }

    private func observeScreenChanges(for window: NSWindow?) {
        guard observedWindow !== window else { return }
        removeScreenObservers()
        observedWindow = window
        guard let window else { return }

        let center = NotificationCenter.default
        screenObservers = [
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window, queue: .main) { [weak self] _ in
                self?.configureWindow()
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.configureWindow()
            }
        ]
    }

    private func removeScreenObservers() {
        let center = NotificationCenter.default
        screenObservers.forEach(center.removeObserver)
        screenObservers.removeAll()
        observedWindow = nil
    }
}

private func tunePanelWindow(_ window: NSWindow?, onHeightAdjusted: ((Double) -> Void)? = nil) {
    guard let window else { return }
    // MenuBarExtra(.window) uses a titled NSPanel under the hood. Its native
    // frame draws the light outline seen outside the SwiftUI clip. Keep the
    // panel itself, but remove only that frame decoration.
    window.styleMask.remove(.titled)
    window.styleMask.remove(.fullSizeContentView)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.contentView?.wantsLayer = true
    window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    window.contentView?.layer?.cornerRadius = 20
    window.contentView?.layer?.masksToBounds = true

    guard let screen = window.screen ?? NSScreen.main else { return }
    let adjustedHeight = PanelWindowSizing.openingHeight(
        window.frame.height,
        visibleScreenHeight: screen.visibleFrame.height
    )
    guard adjustedHeight < window.frame.height else { return }

    var frame = window.frame
    let visibleFrame = screen.visibleFrame
    let top = min(frame.maxY, visibleFrame.maxY)
    frame.size.height = adjustedHeight
    frame.origin.y = max(visibleFrame.minY, top - adjustedHeight)
    window.setFrame(frame, display: true)
    onHeightAdjusted?(Double(adjustedHeight))
}
