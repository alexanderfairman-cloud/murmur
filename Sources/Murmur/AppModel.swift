import AppKit
import MurmurCore
import ServiceManagement
import SwiftUI
import os

/// Everything the window and the menu bar show, in one place, so they can never disagree.
@MainActor
final class AppModel: ObservableObject {
    enum Tab: String, CaseIterable {
        case history, words, settings
    }

    let files: AppFiles
    let history: HistoryStore
    private let log = Logger(subsystem: "com.jamesseriph.murmur", category: "model")

    @Published var tab: Tab = .history
    @Published var settings: MurmurCore.Settings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published private(set) var historyItems: [HistoryItem]
    @Published private(set) var words: WordList
    @Published private(set) var wordUsage: [String: Int] = [:]
    @Published private(set) var dictionaryDamaged = false
    @Published var modelStatus: ModelStatus = .loading(fraction: 0, downloading: false)
    @Published var granted: [Permission: Bool] = [:]
    @Published private(set) var launchAtLogin = false
    @Published private(set) var globeKeyDoesNothing = false
    @Published var isRecording = false

    /// Called when the dictation key is changed in Settings, so the key listener can restart on the new key.
    var onHotkeyChange: (() -> Void)?
    private var dictionaryStamp: Date?

    init(files: AppFiles = AppFiles()) {
        self.files = files
        settings = files.loadSettings()
        history = HistoryStore(url: files.historyURL)
        historyItems = history.items
        do {
            words = WordList(entries: try files.loadDictionary())
        } catch {
            words = WordList()
            dictionaryDamaged = true
        }
        dictionaryStamp = files.dictionaryModified
        wordUsage = words.usage(in: historyItems)
    }

    // MARK: - Status

    var missingPermissions: [Permission] { Permission.allCases.filter { granted[$0] != true } }

    var modelReady: Bool {
        if case .ready = modelStatus { return true }
        return false
    }

    /// Everything needed for dictation to work is in place.
    var setupComplete: Bool { missingPermissions.isEmpty && modelReady }

    enum Health { case ready, setup, failed }

    var health: Health {
        if case .failed = modelStatus { return .failed }
        return setupComplete ? .ready : .setup
    }

    var keyName: String { Self.keyName(settings.hotkey) }

    static func keyName(_ choice: HotkeyChoice) -> String {
        switch choice {
        case .fn: "Fn"
        case .rightOption: "Right ⌥"
        case .rightCommand: "Right ⌘"
        case .rightControl: "Right ⌃"
        }
    }

    var statusLine: String {
        if !missingPermissions.isEmpty { return "Needs your permission to work" }
        if dictionaryDamaged { return "Dictionary file has a typo (check commas and quotes)" }
        switch modelStatus {
        case .ready: return "Ready. Hold \(keyName) and talk"
        case .loading(let fraction, let downloading):
            return downloading ? "Getting the speech model… \(Int(fraction * 100))%" : "Starting up…"
        case .failed: return "The speech model could not load"
        }
    }

    var needsAttention: Bool {
        if !missingPermissions.isEmpty || dictionaryDamaged { return true }
        if case .failed = modelStatus { return true }
        return false
    }

    /// First run: nothing has been dictated yet and setup is unfinished. The window opens by itself.
    var shouldShowWindowAtLaunch: Bool { historyItems.isEmpty && !setupComplete }

    /// Permissions the person has already tried to switch on from the setup card. Used to explain what to do when
    /// one still does not register (macOS keeps a leftover row from an older build, or wants Murmur restarted).
    @Published var tried: Set<Permission> = []

    func allow(_ permission: Permission) {
        tried.insert(permission)
        permission.fix()
    }

    /// Quits and opens Murmur again. Input Monitoring only takes effect in a freshly started app.
    func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// `full` also re-reads the login item and the Globe key setting. The background check every two seconds
    /// skips those, because asking macOS about the login item costs a round trip each time.
    func refreshPermissions(full: Bool = true) {
        var now: [Permission: Bool] = [:]
        for permission in Permission.allCases { now[permission] = permission.isGranted }
        if now != granted {
            granted = now
            log.info("permissions: microphone=\(now[.microphone] == true) accessibility=\(now[.accessibility] == true) inputMonitoring=\(now[.inputMonitoring] == true)")
        }
        guard full else { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        // 0 means "Do Nothing". Anything else, or no value at all, is unknown, so it is never shown as done.
        globeKeyDoesNothing = (UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int) == 0
    }

    // MARK: - Settings

    private func settingsChanged(from old: MurmurCore.Settings) {
        files.saveSettings(settings)
        if settings.hotkey != old.hotkey { onHotkeyChange?() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("login item change failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - History

    func historyChanged() {
        historyItems = history.items
        wordUsage = words.usage(in: historyItems)
    }

    func deleteDictations(_ ids: Set<UUID>) {
        history.remove(ids: ids)
        historyChanged()
    }

    // MARK: - Words

    /// Re-reads dictionary.json if it changed on disk (for example edited by hand).
    func refreshWordsFromDisk() {
        let stamp = files.dictionaryModified
        guard stamp != dictionaryStamp else { return }
        dictionaryStamp = stamp
        do {
            words = WordList(entries: try files.loadDictionary())
            dictionaryDamaged = false
            wordUsage = words.usage(in: historyItems)
        } catch {
            // Keep the last good list rather than silently losing every correction.
            dictionaryDamaged = true
            log.error("dictionary.json could not be read")
        }
    }

    private func commit(_ list: WordList) {
        words = list
        files.saveDictionary(list.entries)
        dictionaryStamp = files.dictionaryModified
        dictionaryDamaged = false
        wordUsage = list.usage(in: historyItems)
    }

    @discardableResult
    func addWord(_ raw: String) -> Bool {
        refreshWordsFromDisk()
        var list = words
        guard list.add(raw) else { return false }
        commit(list)
        return true
    }

    func deleteWords(_ names: Set<String>) {
        refreshWordsFromDisk()
        var list = words
        list.remove(names)
        commit(list)
    }

    @discardableResult
    func addHeardAs(_ raw: String, to word: String) -> Bool {
        refreshWordsFromDisk()
        var list = words
        guard list.addHeardAs(raw, to: word) else { return false }
        commit(list)
        return true
    }

    func removeHeardAs(_ heard: String, from word: String) {
        refreshWordsFromDisk()
        var list = words
        list.removeHeardAs(heard, from: word)
        commit(list)
    }

    /// "Fix a word" in History. Records the wrong spelling under the right word (creating the word if it is new),
    /// and corrects the saved text of that dictation. Returns nil when the choice or the word is not valid.
    /// Murmur cannot change text already typed in another app; this teaches it for next time.
    func fixWord(in itemID: UUID, words range: ClosedRange<Int>, to correct: String) -> FixResult? {
        guard let item = historyItems.first(where: { $0.id == itemID }) else { return nil }
        let right = correct.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !right.isEmpty, !right.contains(where: \.isNewline) else { return nil }
        let tokens = FixTokens(item.text)
        let heard = tokens.heard(range)
        guard !heard.isEmpty, tokens.replacing(range, with: right) != nil else { return nil }

        refreshWordsFromDisk()
        var list = words
        var created = false
        let written: String
        if let existing = list.entries.first(where: { $0.word.caseInsensitiveCompare(right) == .orderedSame }) {
            written = existing.word // the spelling already in Words wins over how it was typed just now
        } else {
            list.add(right)
            written = right
            created = true
        }
        let ruleAdded = list.claim(heard, for: written)
        guard let replaced = tokens.replacing(range, with: written) else { return nil }

        commit(list)
        var updated = item
        updated.text = replaced.text
        updated.corrections.append(Correction(heard: heard, written: written))
        history.replace(updated)
        historyChanged()
        return FixResult(
            heard: heard, written: written, createdWord: created, ruleAdded: ruleAdded,
            newText: replaced.text, range: replaced.range)
    }

    /// What the dictation pipeline uses to fix names. Always reflects the latest list.
    func corrector() -> DictionaryCorrector {
        refreshWordsFromDisk()
        return DictionaryCorrector(entries: words.entries, isKnownWord: Self.isRealWord)
    }

    nonisolated static func isRealWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
    }
}
