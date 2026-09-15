#!/usr/bin/env swift
import AppKit

// Render the same stack symbol as the menu-bar item into a macOS app icon.
// The generated .icns is committed so release builds use identical artwork.
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = repository.appendingPathComponent("swift-prototype/Packaging/AppIcon.icns")
let preview = repository.appendingPathComponent("docs/design/stackhub-app-icon.png")
let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("StackHubIcon-\(UUID())", isDirectory: true)
let iconset = temporary.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func render(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "StackHubIcon", code: 1)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer { NSGraphicsContext.restoreGraphicsState() }
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let shape = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 184, yRadius: 184)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor(calibratedRed: 0.13, green: 0.34, blue: 0.83, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.32, blue: 0.85, alpha: 1),
               ending: NSColor(calibratedRed: 0.23, green: 0.64, blue: 0.99, alpha: 1))!.draw(in: shape, angle: 90)

    let configuration = NSImage.SymbolConfiguration(pointSize: 512, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "StackHub")?
        .withSymbolConfiguration(configuration) else {
        throw NSError(domain: "StackHubIcon", code: 2)
    }
    symbol.isTemplate = false
    let scale = min(530 / symbol.size.width, 560 / symbol.size.height)
    let width = symbol.size.width * scale
    let height = symbol.size.height * scale
    symbol.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2 + 8, width: width, height: height))
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = try render(size: points * scale)
        try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
        if points == 512 && scale == 2 { try data.write(to: preview) }
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Generated \(output.path)")
