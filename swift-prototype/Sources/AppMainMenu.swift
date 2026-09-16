import AppKit

/// The custom NSApplication entry point has no storyboard or SwiftUI App scene
/// to provide Edit commands. Native text controls need these key equivalents.
@MainActor
enum AppMainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        let appMenu = NSMenu(title: "StackHub")
        appMenu.addItem(withTitle: L("退出 StackHub"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, to: menu)

        let editMenu = NSMenu(title: L("编辑"))
        editMenu.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        // Leave targets nil so AppKit validates and dispatches through the
        // focused control, including field editors, secure fields, and sheets.
        addSubmenu(editMenu, to: menu)
        return menu
    }

    private static func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }
}
