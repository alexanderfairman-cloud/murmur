import AppKit
import MurmurCore
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MenuBarDelegate {
    private let model = AppModel()
    private let hud = HUDController()
    private let transcriber = Transcriber()
    private var dictation: DictationController!
    private var menuBar: MenuBarController!
    private var window: MainWindowController!
    private var hotkey: HotkeyMonitor?
    private var watchdog: Timer?
    private let log = Logger(subsystem: "com.jamesseriph.murmur", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
        dictation = DictationController(
            transcriber: transcriber, hud: hud, history: model.history,
            settings: { [unowned self] in model.settings },
            corrector: { [unowned self] in model.corrector() },
            modelStatus: { [unowned self] in model.modelStatus }
        )
        dictation.onPhaseChange = { [weak self] _ in
            guard let self else { return }
            model.isRecording = dictation.isRecording
            menuBar.refreshIcon()
        }
        dictation.onHistoryChange = { [weak self] in self?.model.historyChanged() }
        model.onHotkeyChange = { [weak self] in self?.restartHotkey() }
        window = MainWindowController(model: model)
        menuBar = MenuBarController(delegate: self)

        model.refreshPermissions()
        loadModel()
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
        // The very first time, the window opens by itself so the setup steps are in front of you.
        if model.shouldShowWindowAtLaunch { window.show(.history) }
    }

    /// Clicking Murmur in the Dock, or opening it again from Finder, brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.show()
        return true
    }

    // MARK: - Speech model

    private func loadModel() {
        let modelCache = ModelCacheGuard.forThisMac(files: model.files)
        if modelCache?.prepare() == true {
            log.info("threw away the saved copy of the speech model (the Mac restarted, or the last start did not finish)")
        }
        Task {
            do {
                try await transcriber.load { fraction, downloading in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        model.modelStatus = .loading(fraction: fraction, downloading: downloading)
                        // The window shows this itself. The floating bar is for when the window is closed.
                        if downloading, !dictation.isRecording, !window.isVisible { hud.progress(fraction) }
                    }
                }
                modelCache?.finished()
                model.modelStatus = .ready
                hud.hide()
                log.info("speech model ready")
            } catch {
                model.modelStatus = .failed
                hud.message("The speech model could not load", seconds: 5)
                log.error("model load failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Keeping the key listener alive

    private func tick() {
        model.refreshPermissions(full: false)
        let canListen = model.granted[.accessibility] == true && model.granted[.inputMonitoring] == true
        if let hotkey {
            // A permission taken away in System Settings kills the listener; drop it so it can restart cleanly.
            if canListen { hotkey.ensureEnabled() } else {
                hotkey.stop()
                self.hotkey = nil
            }
        } else if canListen {
            startHotkey()
        }
        menuBar.refreshIcon()
    }

    private func restartHotkey() {
        hotkey?.stop()
        hotkey = nil
        tick()
    }

    private func startHotkey() {
        let monitor = HotkeyMonitor(key: HotkeyMonitor.key(for: model.settings.hotkey))
        monitor.onPress = { [weak self] in self?.dictation.keyPressed() }
        monitor.onRelease = { [weak self] in self?.dictation.keyReleased() }
        monitor.onSpaceWhileHeld = { [weak self] in self?.dictation.lock() ?? false }
        monitor.onOtherKeyWhileHeld = { [weak self] in self?.dictation.cancelShortcut() }
        monitor.onEscape = { [weak self] in self?.dictation.cancel() ?? false }
        monitor.onPasteLast = { [weak self] in self?.dictation.pasteLast() ?? false }
        if monitor.start() {
            hotkey = monitor
            log.info("listening for the \(self.model.settings.hotkey.rawValue) key")
        } else {
            log.error("macOS refused the key listener")
        }
    }

    // MARK: - MenuBarDelegate

    var statusLine: String { model.statusLine }
    var needsAttention: Bool { model.needsAttention }
    var missingPermissions: [Permission] { model.missingPermissions }
    var recentTexts: [String] { model.history.recent(5).map(\.text) }
    var isRecording: Bool { dictation?.isRecording ?? false }

    func openWindow() { window.show() }
    func toggleDictation() { dictation.toggle() }
    func copy(_ text: String) { TextInjector.copy(text) }
    func fix(_ permission: Permission) { model.allow(permission) }
    func quit() { NSApp.terminate(nil) }
}
