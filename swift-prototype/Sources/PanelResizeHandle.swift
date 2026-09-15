import SwiftUI
import AppKit

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
        let minimum: CGFloat = 500
        let screenMaximum = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        let maximum = max(minimum, min(CGFloat(820), screenMaximum - 36))
        let newHeight = min(max(startHeight + delta, minimum), maximum)
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
    func makeNSView(context: Context) -> PanelWindowTuningView {
        PanelWindowTuningView(frame: .zero)
    }

    func updateNSView(_ nsView: PanelWindowTuningView, context: Context) {
        configureWindow(nsView.window)
    }
}

final class PanelWindowTuningView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow(window)
        // MenuBarExtra may apply its panel style one run-loop later; applying
        // once more after attachment makes the border removal deterministic.
        DispatchQueue.main.async { [weak self] in configureWindow(self?.window) }
    }
}

private func configureWindow(_ window: NSWindow?) {
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
}
