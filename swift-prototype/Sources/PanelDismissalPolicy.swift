import AppKit

/// Sheets and child windows belong to the panel even though their mouse events
/// have a different window. Never hide their host before AppKit handles a click.
@MainActor
enum PanelDismissalPolicy {
    static func isPresentingModal(panel: NSWindow, modalWindow: NSWindow?) -> Bool {
        panel.attachedSheet != nil || modalWindow != nil
    }

    static func shouldDismiss(panel: NSWindow, clickedWindow: NSWindow?, modalWindow: NSWindow?) -> Bool {
        // Keep the host visible until its sheet or an app-modal dialog closes,
        // including when a click comes from another application.
        guard !isPresentingModal(panel: panel, modalWindow: modalWindow) else { return false }
        var window = clickedWindow
        while let current = window {
            if current === panel { return false }
            window = current.sheetParent ?? current.parent
        }
        return true
    }
}
