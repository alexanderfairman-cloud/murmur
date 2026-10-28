import AppKit
import ApplicationServices

enum TextInjector {
    /// Tags the key presses Murmur sends itself, so its own key listener can tell them apart from yours.
    static let syntheticMarker: Int64 = 0x4D55_524D

    private typealias SavedItem = [(NSPasteboard.PasteboardType, Data)]

    /// Types `text` at the cursor of whatever app is in front by pasting it, then puts your clipboard back.
    /// Pasting works in every app, including Electron ones (Cursor, Slack, VS Code) where direct typing silently fails.
    /// Returns false when macOS will not let Murmur press the paste keys; the text is then left on the clipboard.
    @MainActor
    static func insert(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        // Tells clipboard managers (Raycast, Paste, Maccy) not to keep this in their history.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ourChange = pasteboard.changeCount

        guard AXIsProcessTrusted() else { return false }
        pressCommandV()

        // Give the app a moment to read the clipboard, then put yours back, unless you copied something new meanwhile.
        try? await Task.sleep(for: .milliseconds(600))
        if pasteboard.changeCount == ourChange { restore(saved, to: pasteboard) }
        return true
    }

    /// Puts text on the clipboard and nothing else. Used when pasting is not possible.
    @MainActor
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: keyDown) else { continue }
            // Exactly Command, so a key you are still holding (like Fn) cannot turn this into a different shortcut.
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [SavedItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private static func restore(_ saved: [SavedItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
}
