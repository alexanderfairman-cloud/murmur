import AppKit
import SwiftUI

/// Owns the Murmur window. While the window is open Murmur shows in the Dock and has a menu; when it closes,
/// Murmur goes back to living only in the menu bar.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ tab: AppModel.Tab? = nil) {
        if let tab { model.tab = tab }
        if window == nil {
            let made = Self.makeWindow(model: model)
            made.delegate = self
            made.setFrameAutosaveName("MurmurMainWindow")
            if !made.setFrameUsingName("MurmurMainWindow") { made.center() }
            window = made
        }
        model.refreshPermissions()
        model.refreshWordsFromDisk()
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// The window and everything in it. Also used, without being shown, to draw pictures of every screen for the checks.
    static func makeWindow(model: AppModel, historyOpen: Set<UUID> = [], historyFix: [UUID: FixState] = [:], size: NSSize = NSSize(width: 840, height: 600)) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 480)
        window.title = "Murmur"
        window.contentView = NSHostingView(rootView: MainView(model: model, historyOpen: historyOpen, historyFix: historyFix))
        return window
    }
}

/// The menu bar at the top of the screen while the window is open. Without an Edit menu, copy and paste
/// would not work in the search and word boxes.
enum MainMenu {
    @MainActor
    static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Murmur", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Murmur", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        attach(app, titled: "Murmur", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        attach(edit, titled: "Edit", to: main)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        attach(windowMenu, titled: "Window", to: main)
        NSApp.windowsMenu = windowMenu

        return main
    }

    private static func attach(_ menu: NSMenu, titled title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        main.addItem(item)
    }
}
