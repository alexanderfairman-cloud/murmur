import AppKit
import MurmurCore

@MainActor
protocol MenuBarDelegate: AnyObject {
    var statusLine: String { get }
    var needsAttention: Bool { get }
    var missingPermissions: [Permission] { get }
    var recentTexts: [String] { get }
    var isRecording: Bool { get }
    func openWindow()
    func toggleDictation()
    func copy(_ text: String)
    func fix(_ permission: Permission)
    func quit()
}

/// The icon at the top of the screen and the menu under it.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private unowned let delegate: MenuBarDelegate

    init(delegate: MenuBarDelegate) {
        self.delegate = delegate
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshIcon()
    }

    /// Waveform when ready, a red microphone while listening, a warning sign when something needs fixing.
    func refreshIcon() {
        let name = delegate.isRecording ? "mic.fill" : (delegate.needsAttention ? "exclamationmark.triangle" : "waveform")
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Murmur")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.contentTintColor = delegate.isRecording ? .systemRed : nil
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: delegate.statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        for permission in delegate.missingPermissions {
            let fix = NSMenuItem(
                title: "Allow \(permission.title) (\(permission.reason))…",
                action: #selector(fixPermission(_:)), keyEquivalent: "")
            fix.target = self
            fix.representedObject = permission
            menu.addItem(fix)
        }

        menu.addItem(.separator())
        addAction(menu, "Open Murmur", #selector(openWindow))
        let toggle = NSMenuItem(
            title: delegate.isRecording ? "Stop dictating" : "Start dictating",
            action: #selector(toggleDictation), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let recent = delegate.recentTexts
        if !recent.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for text in recent {
                let line = text.replacingOccurrences(of: "\n", with: " ")
                let row = NSMenuItem(
                    title: line.count > 56 ? String(line.prefix(56)) + "…" : line,
                    action: #selector(copyRecent(_:)), keyEquivalent: "")
                row.target = self
                row.representedObject = text
                menu.addItem(row)
            }
        }

        menu.addItem(.separator())
        addAction(menu, "Quit Murmur", #selector(quit), key: "q")
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func fixPermission(_ sender: NSMenuItem) {
        if let permission = sender.representedObject as? Permission { delegate.fix(permission) }
    }
    @objc private func openWindow() { delegate.openWindow() }
    @objc private func toggleDictation() { delegate.toggleDictation() }
    @objc private func copyRecent(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { delegate.copy(text) }
    }
    @objc private func quit() { delegate.quit() }
}
