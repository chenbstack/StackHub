import AppKit
import SwiftUI

/// A native log viewport keeps scroll position and text selection independent
/// of SwiftUI's text updates. Following resumes when the user reaches the end.
struct FollowingLogView: NSViewRepresentable {
    let text: String
    var isPlaceholder = false

    func makeNSView(context: Context) -> FollowingLogScrollView {
        FollowingLogScrollView()
    }

    func updateNSView(_ view: FollowingLogScrollView, context: Context) {
        view.setLog(text, isPlaceholder: isPlaceholder)
    }
}

final class FollowingLogScrollView: NSScrollView {
    let logTextView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 1))
    private var previousText: String?
    private var previousPlaceholder = false
    private var updating = false

    var isAtBottom: Bool {
        guard let documentView else { return true }
        return documentView.frame.height - contentView.bounds.maxY <= 2
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .overlay
        autohidesScrollers = true
        scrollerKnobStyle = .light
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.drawsBackground = false
        logTextView.isRichText = false
        logTextView.isVerticallyResizable = true
        logTextView.isHorizontallyResizable = false
        logTextView.autoresizingMask = [.width]
        logTextView.minSize = .zero
        logTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logTextView.textContainerInset = NSSize(width: 14, height: 14)
        logTextView.textContainer?.widthTracksTextView = true
        logTextView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        documentView = logTextView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        let follow = previousText == nil || isAtBottom
        super.layout()
        guard !updating, follow else { return }
        scrollToBottom()
    }

    func setLog(_ text: String, isPlaceholder: Bool = false) {
        guard text != previousText || isPlaceholder != previousPlaceholder else { return }
        let follow = previousText == nil || text.isEmpty || isPlaceholder || isAtBottom
        let origin = contentView.bounds.origin
        let selection = logTextView.selectedRanges
        updating = true
        defer { updating = false }

        let rendered = NSMutableAttributedString(string: "")
        for segment in ANSILogRenderer.segments(from: text) {
            let color = isPlaceholder ? NSColor.secondaryLabelColor
                : segment.foreground.map { NSColor($0.swiftUIColor) } ?? NSColor.white
            rendered.append(NSAttributedString(string: segment.text, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: color
            ]))
        }
        logTextView.textStorage?.setAttributedString(rendered)
        logTextView.layoutManager?.ensureLayout(for: logTextView.textContainer!)
        logTextView.sizeToFit()
        layoutSubtreeIfNeeded()
        logTextView.selectedRanges = selection.map {
            let range = $0.rangeValue
            let location = min(range.location, rendered.length)
            return NSValue(range: NSRange(location: location, length: min(range.length, rendered.length - location)))
        }
        previousText = text
        previousPlaceholder = isPlaceholder
        if follow {
            scrollToBottom()
        } else {
            contentView.scroll(to: NSPoint(x: origin.x, y: min(origin.y, maximumOffset)))
            reflectScrolledClipView(contentView)
        }
    }

    private var maximumOffset: CGFloat {
        max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
    }

    private func scrollToBottom() {
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: maximumOffset))
        reflectScrolledClipView(contentView)
    }
}
