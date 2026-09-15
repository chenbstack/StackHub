import AppKit
import CoreText

@MainActor
enum MenuBarStatusImage {
    static func make(running: Int, failures: Int) -> NSImage {
        let labels = [running > 0 ? "RUN \(running)" : nil, failures > 0 ? "FAIL \(failures)" : nil].compactMap { $0 }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 7, weight: .medium),
            .foregroundColor: NSColor.white,
            .kern: -0.15
        ]
        let lines = labels.map { CTLineCreateWithAttributedString(NSAttributedString(string: $0, attributes: attributes)) }
        let bounds = lines.map { CTLineGetBoundsWithOptions($0, .useGlyphPathBounds) }
        let textWidth = ceil(bounds.map(\.width).max() ?? 0)
        let size = NSSize(width: labels.isEmpty ? 18 : 24 + textWidth, height: 18)
        let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "StackHub")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))
        symbol?.isTemplate = false

        let image = NSImage(size: size, flipped: false) { _ in
            if let symbol {
                let scale = min(18 / symbol.size.width, 18 / symbol.size.height)
                let width = symbol.size.width * scale
                let height = symbol.size.height * scale
                symbol.draw(in: NSRect(x: (18 - width) / 2, y: (18 - height) / 2, width: width, height: height))
            }
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Center the visible glyphs as one block. A single RUN or FAIL
            // occupies the same vertical center as the two-line combination.
            let gap: CGFloat = 1.5
            let blockHeight = bounds.reduce(0) { $0 + $1.height } + CGFloat(max(0, lines.count - 1)) * gap
            var top = (size.height + blockHeight) / 2
            for (line, bounds) in zip(lines, bounds) {
                context.textPosition = CGPoint(x: 24 - bounds.minX, y: top - bounds.maxY)
                CTLineDraw(line, context)
                top -= bounds.height + gap
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = (["StackHub"] + labels).joined(separator: ", ")
        return image
    }
}
