import AppKit
import XCTest
@testable import StackHub

final class AppMainMenuTests: XCTestCase {
    @MainActor
    func testCopyAndSelectAllUseTheReadOnlyLogSelection() throws {
        try withEditingWindow { window, menu in
            let log = NSTextView(frame: window.contentView!.bounds)
            log.isEditable = false
            log.isSelectable = true
            log.string = "First line\nSelected log line\nLast line"
            window.contentView = log
            XCTAssertTrue(window.makeFirstResponder(log))
            log.setSelectedRange((log.string as NSString).range(of: "Selected log line"))

            XCTAssertTrue(perform(key("c", in: window), menu: menu, window: window))
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Selected log line")
            XCTAssertTrue(perform(key("a", in: window), menu: menu, window: window))
            XCTAssertEqual(log.selectedRange(), NSRange(location: 0, length: (log.string as NSString).length))
            _ = perform(key("v", in: window), menu: menu, window: window)
            XCTAssertEqual(log.string, "First line\nSelected log line\nLast line", "Paste must not change read-only logs")
            XCTAssertFalse(perform(key("c", modifiers: [.command, .option], in: window), menu: menu, window: window))
        }
    }

    @MainActor
    func testPasteCutAndUndoUseTheFocusedTextFieldEditor() throws {
        try withEditingWindow { window, menu in
            let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 240, height: 24))
            field.stringValue = "Original"
            window.contentView!.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.allowsUndo = true
            XCTAssertTrue(perform(key("a", in: window), menu: menu, window: window))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Pasted command", forType: .string)

            XCTAssertTrue(perform(key("v", in: window), menu: menu, window: window))
            XCTAssertEqual(editor.string, "Pasted command")
            XCTAssertTrue(perform(key("z", in: window), menu: menu, window: window))
            XCTAssertEqual(editor.string, "Original")
            XCTAssertTrue(perform(key("z", modifiers: [.command, .shift], in: window), menu: menu, window: window))
            XCTAssertEqual(editor.string, "Pasted command")
            XCTAssertTrue(perform(key("a", in: window), menu: menu, window: window))
            XCTAssertTrue(perform(key("x", in: window), menu: menu, window: window))
            XCTAssertEqual(editor.string, "")
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Pasted command")
        }
    }

    @MainActor
    func testPasteReachesTheSecureFieldEditor() throws {
        try withEditingWindow { window, menu in
            let field = NSSecureTextField(frame: NSRect(x: 10, y: 10, width: 240, height: 24))
            window.contentView!.addSubview(field)
            XCTAssertTrue(window.makeFirstResponder(field))
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("test-token-only", forType: .string)

            XCTAssertTrue(perform(key("v", in: window), menu: menu, window: window))
            XCTAssertEqual(editor.string, "test-token-only")
        }
    }

    @MainActor
    private func withEditingWindow(_ body: (NSPanel, NSMenu) throws -> Void) throws {
        _ = NSApplication.shared
        let clipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let menu = AppMainMenu.make()
        let window = EditingTestPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
                                      styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.close()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(clipboard.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        NSPasteboard.general.clearContents()
        try body(window, menu)
    }

    @MainActor
    private func perform(_ event: NSEvent, menu: NSMenu, window: NSWindow) -> Bool {
        // XCTest has no active application window. Resolve this test window's
        // responder chain explicitly, then exercise native menu validation,
        // key-equivalent matching, and editing behavior without stealing focus.
        let commands = menu.items.compactMap(\.submenu).flatMap(\.items)
        defer { commands.forEach { $0.target = nil } }
        for command in commands {
            XCTAssertNil(command.target, "Production commands must follow focus rather than pinning a target")
            guard let action = command.action else { continue }
            var responder = window.firstResponder
            while let current = responder, !current.responds(to: action) { responder = current.nextResponder }
            command.target = responder
        }
        menu.items.compactMap(\.submenu).forEach { $0.update() }
        return menu.performKeyEquivalent(with: event)
    }

    @MainActor
    private func key(_ character: String, modifiers: NSEvent.ModifierFlags = .command, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                        characters: modifiers.contains(.shift) ? character.uppercased() : character,
                        charactersIgnoringModifiers: modifiers.contains(.shift) ? character.uppercased() : character,
                        isARepeat: false, keyCode: 0)!
    }
}

private final class EditingTestPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
