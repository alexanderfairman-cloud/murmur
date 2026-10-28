import AppKit
import AVFoundation
import Foundation
import MurmurCore
import SwiftUI

/// `Murmur --transcribe some.wav` runs the same speech-to-text and cleanup as the app on an audio file,
/// prints the result as JSON, and exits. It is what Scripts/check.sh uses to test the app without a microphone.
enum CLI {
    /// `Murmur --render-hud some-folder` draws every state of the floating bar to PNG files, so the look can be checked
    /// without a microphone or screen access.
    @MainActor
    static func renderHUD(into folder: String) -> Never {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = HUDModel()
        // A believable stretch of speech: quiet, then louder, then trailing off.
        let speech: [Float] = (0..<HUDModel.barCount).map { i in
            let t = Float(i) / Float(HUDModel.barCount)
            return min(1, 0.12 + 0.8 * abs(sin(t * 9)) * (1 - t * 0.5))
        }
        let states: [(String, HUDModel.Mode)] = [
            ("listening", .listening(locked: false)),
            ("handsfree", .listening(locked: true)),
            ("thinking", .thinking),
            ("message", .message("Didn't hear anything")),
            ("download", .download(0.42)),
        ]
        var failed = false
        for (name, mode) in states {
            model.mode = mode
            model.levels = speech
            let scene = HUDView(model: model)
                .frame(width: 420, height: 72)
                .background(Color(white: 0.93))
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            guard let tiff = renderer.nsImage?.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else {
                failed = true
                continue
            }
            try? png.write(to: directory.appendingPathComponent("hud-\(name).png"))
        }
        exit(failed ? 1 : 0)
    }

    /// `Murmur --mic-test 2` listens to the current microphone for that many seconds, keeps nothing, and prints which
    /// microphone it was, how long it took to start, how much sound arrived and how loud it was. For when dictation
    /// stops working. Start it with `open -n --stdout <file> Murmur.app --args --mic-test 2` so it uses Murmur's own permission.
    static func micTest(seconds: Double) -> Never {
        let device = AVCaptureDevice.default(for: .audio)?.localizedName ?? "none"
        let recorder = AudioRecorder()
        let beganAt = Date()
        var report: [String: Any] = ["systemDefaultMicrophone": device, "microphoneAllowed": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized]
        do {
            report["microphoneUsed"] = try recorder.start(preferBuiltIn: true)
        } catch {
            report["error"] = error.localizedDescription
            report["startedInMs"] = Int(Date().timeIntervalSince(beganAt) * 1000)
            print(String(decoding: (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
            exit(1)
        }
        report["startedInMs"] = Int(Date().timeIntervalSince(beganAt) * 1000)
        Thread.sleep(forTimeInterval: seconds)
        let samples = recorder.stop()
        let peak = samples.map { abs($0) }.max() ?? 0
        let rms = samples.isEmpty ? 0 : (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        report["askedSeconds"] = seconds
        report["gotSeconds"] = (Double(samples.count) / 16_000 * 100).rounded() / 100
        report["peak"] = (Double(peak) * 1000).rounded() / 1000
        report["rms"] = (Double(rms) * 10000).rounded() / 10000
        report["verdict"] = samples.isEmpty ? "NO SOUND ARRIVED" : (peak == 0 ? "ALL ZEROS (muted or blocked)" : "OK, sound is arriving")
        print(String(decoding: (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data(), as: UTF8.self))
        exit(0)
    }

    /// `Murmur --selftest-model` runs everything the window's buttons do (add and delete words, save settings,
    /// delete a dictation, survive a damaged dictionary) against a temporary folder, and prints what failed.
    @MainActor
    static func selfTestModel() -> Never {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        var failures: [String] = []
        var total = 0
        func check(_ ok: Bool, _ what: String) {
            total += 1
            if !ok { failures.append(what) }
        }

        let files = AppFiles(directory: work)
        let model = AppModel(files: files)

        // Words
        check(model.addWord("Wyld"), "adding a new word")
        check(!model.addWord("wyld"), "refusing a repeat")
        check(model.words.entries.first?.word == "Wyld", "new word goes to the top")
        check(model.addHeardAs("Wild", to: "Wyld"), "adding a wrong spelling")
        check(AppModel(files: files).words.entries.first?.heardAs == ["wild"], "words are saved to disk")
        check(model.corrector().apply(to: "I met wild yesterday").text == "I met Wyld yesterday", "dictation uses the new word at once")
        model.removeHeardAs("wild", from: "Wyld")
        check(model.words.entries.first?.heardAs.isEmpty == true, "removing a wrong spelling")
        model.deleteWords(["Wyld"])
        check(!model.words.contains("Wyld"), "deleting a word")

        // Settings
        var hotkeyChanges = 0
        model.onHotkeyChange = { hotkeyChanges += 1 }
        model.settings.hotkey = .rightOption
        model.settings.sounds = false
        model.settings.sentencePause = 1.1
        let saved = files.loadSettings()
        check(hotkeyChanges == 1, "changing the key restarts the key listener once")
        check(saved.hotkey == .rightOption && !saved.sounds && saved.sentencePause == 1.1, "settings are saved to disk")
        model.settings.sounds = false
        check(hotkeyChanges == 1, "an unrelated setting does not restart the listener")

        // History
        let keep = HistoryItem(text: "keep", rawText: "keep", audioSeconds: 1, transcribeMs: 1, app: "Notes", appID: "com.apple.Notes", corrections: [])
        let drop = HistoryItem(text: "drop", rawText: "drop", audioSeconds: 1, transcribeMs: 1, app: nil, corrections: [])
        model.history.append(keep)
        model.history.append(drop)
        model.historyChanged()
        check(model.historyItems.count == 2, "history shows new dictations")
        model.deleteDictations([drop.id])
        check(model.historyItems.map(\.text) == ["keep"] && HistoryStore(url: files.historyURL).items.map(\.text) == ["keep"],
              "deleting a dictation removes it from disk")

        // A hand-edited dictionary with a typo must not wipe the list
        model.addWord("Samir")
        Thread.sleep(forTimeInterval: 0.05)
        try? Data("{ \"entries\": [ oops".utf8).write(to: files.dictionaryURL)
        model.refreshWordsFromDisk()
        check(model.dictionaryDamaged && model.words.contains("Samir"), "a damaged dictionary file keeps the last good list and says so")
        model.addWord("Sara")
        check(!model.dictionaryDamaged && AppModel(files: files).words.contains("Sara"), "saving from the window repairs the file")

        // Fix a word (what the Save button in History calls)
        let fixModel = AppModel(files: AppFiles(directory: work.appendingPathComponent("fix")))
        fixModel.addWord("Jyoti")
        let ask = HistoryItem(text: "Ask Jodi, then tell her about it.", rawText: "Ask Jodi, then tell her about it.",
                              audioSeconds: 2, transcribeMs: 100, app: "Notes", corrections: [])
        let call = HistoryItem(text: "Call Jodi tomorrow", rawText: "Call Jodi tomorrow", audioSeconds: 2, transcribeMs: 100, app: nil, corrections: [])
        fixModel.history.append(ask)
        fixModel.history.append(call)
        fixModel.historyChanged()
        let fixed = fixModel.fixWord(in: ask.id, words: 1...1, to: "jyoti")
        check(fixed?.newText == "Ask Jyoti, then tell her about it.", "fixing a word keeps the punctuation and uses the Words spelling")
        check(fixed?.ruleAdded == true && fixed?.createdWord == false, "fixing reports a new wrong spelling, not a new word")
        check(fixModel.words.entries.first { $0.word == "Jyoti" }?.heardAs == ["jodi"], "the wrong spelling is saved under the word")
        check(fixModel.corrector().apply(to: "I asked jodi").text == "I asked Jyoti", "the next dictation uses the fix")
        check(HistoryStore(url: fixModel.files.historyURL).items.map(\.text).contains("Ask Jyoti, then tell her about it."),
              "the corrected text is saved to disk")
        check(fixModel.historyItems.first { $0.id == ask.id }?.corrections.last == Correction(heard: "Jodi", written: "Jyoti"),
              "the fix is recorded on the dictation")
        let created = fixModel.fixWord(in: ask.id, words: 4...4, to: "Jara")
        check(created?.createdWord == true && fixModel.words.contains("Jara"), "fixing to a new word creates it")
        check(fixModel.words.entries.first { $0.word == "Jara" }?.heardAs == ["her"], "even an everyday word is saved when asked")
        _ = fixModel.fixWord(in: call.id, words: 1...1, to: "Jara")
        check(fixModel.words.entries.first { $0.word == "Jyoti" }?.heardAs.isEmpty == true
              && fixModel.words.entries.first { $0.word == "Jara" }?.heardAs.contains("jodi") == true,
              "a spelling moves to the word chosen last")
        check(fixModel.fixWord(in: ask.id, words: 0...99, to: "x") == nil, "a choice outside the text is refused")
        check(fixModel.fixWord(in: ask.id, words: 0...0, to: "   ") == nil, "an empty word is refused")

        if failures.isEmpty {
            print("PASS: \(total) checks of what the window's buttons do")
            exit(0)
        }
        for failure in failures { print("FAIL: \(failure)") }
        exit(1)
    }

    /// `Murmur --render-window some-folder` draws each screen of the Murmur window, with sample data in a temporary
    /// folder (never your real dictations), to PNG files. It is how the window is looked at without clicking through it.
    @MainActor
    static func renderWindows(into folder: String) -> Never {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }

        func sample(_ hoursAgo: Double, daysAgo: Int = 0, _ text: String, raw: String? = nil, app: String, id: String,
                    seconds: Double, ms: Int, fixes: [Correction] = []) -> HistoryItem {
            let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
            return HistoryItem(
                date: day.addingTimeInterval(-hoursAgo * 3600), text: text, rawText: raw ?? text,
                audioSeconds: seconds, transcribeMs: ms, app: app, appID: id, corrections: fixes)
        }
        let items = [
            sample(0.2, "Can you check the Supabase migration before we ship on Friday? I think the new column needs a default.",
                   raw: "Can you check the super base migration before we ship on Friday? I think the new column needs a default.",
                   app: "Terminal", id: "com.apple.Terminal", seconds: 4.2, ms: 122,
                   fixes: [Correction(heard: "super base", written: "Supabase")]),
            sample(0.6, "Sounds good, I'll send the Vercel preview link in a few minutes.",
                   app: "Slack", id: "com.tinyspeck.slackmacgap", seconds: 3.1, ms: 111,
                   fixes: [Correction(heard: "versel", written: "Vercel")]),
            sample(1.1, "Ideas for the launch. One, a tighter onboarding. Two, a shorter first report.\n\nThree, ask Sam for feedback.",
                   app: "Notes", id: "com.apple.Notes", seconds: 7.8, ms: 190),
            sample(1.6, "Hi Sam, thanks for the call yesterday. I've put the three upgrades into one pull request and I'll send the link once the checks are green.",
                   app: "Mail", id: "com.apple.mail", seconds: 9.4, ms: 240),
            sample(2.4, "Run the tests again and tell me which one failed first.",
                   app: "Terminal", id: "com.apple.Terminal", seconds: 3.0, ms: 110),
            sample(5, daysAgo: 1, "Running ten minutes late, start without me.",
                   app: "Messages", id: "com.apple.MobileSMS", seconds: 2.2, ms: 100),
            sample(7, daysAgo: 1, "Can we move the review to Thursday morning?",
                   app: "Slack", id: "com.tinyspeck.slackmacgap", seconds: 2.6, ms: 105),
        ]

        func makeModel(_ name: String, history: [HistoryItem], words: [DictionaryEntry], healthy: Bool) -> AppModel {
            let files = AppFiles(directory: work.appendingPathComponent(name))
            files.saveDictionary(words)
            let store = HistoryStore(url: files.historyURL)
            for item in history.reversed() { store.append(item) } // oldest first, so the newest ends up on top
            let model = AppModel(files: files)
            if healthy {
                for permission in Permission.allCases { model.granted[permission] = true }
                model.modelStatus = .ready
            } else {
                model.granted = [.microphone: true, .accessibility: false, .inputMonitoring: false]
                model.modelStatus = .loading(fraction: 0.42, downloading: true)
            }
            return model
        }

        func snapshot(_ model: AppModel, open: Set<UUID> = [], fix: [UUID: FixState] = [:], dark: Bool = false, to name: String) -> Bool {
            let window = MainWindowController.makeWindow(model: model, historyOpen: open, historyFix: fix)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            guard let view = window.contentView else { return false }
            view.frame = NSRect(x: 0, y: 0, width: 840, height: 600)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: directory.appendingPathComponent("window-\(name).png"))) != nil
        }

        let starter = AppFiles.starterDictionary
        let history = makeModel("history", history: items, words: starter, healthy: true)
        var ok = snapshot(history, open: [history.historyItems[0].id, history.historyItems[2].id], to: "history")
        ok = snapshot(history, open: [history.historyItems[0].id], dark: true, to: "history-dark") && ok

        let words = makeModel("words", history: items, words: starter, healthy: true)
        words.tab = .words
        ok = snapshot(words, to: "words") && ok

        let settings = makeModel("settings", history: items, words: starter, healthy: true)
        settings.tab = .settings
        ok = snapshot(settings, to: "settings") && ok

        let firstRun = makeModel("first", history: [], words: starter, healthy: false)
        ok = snapshot(firstRun, to: "first-run") && ok

        // The three steps of Fix a word, on a dictation with a misheard name and an everyday word.
        let fixText = "Ask Annabelle and Jodi about the Enneagram, and tell her the OKRs are fine."
        let fixItem = sample(0.2, fixText, app: "Terminal", id: "com.apple.Terminal", seconds: 4.0, ms: 120)
        let fixWords = starter + [DictionaryEntry(word: "Jyoti"), DictionaryEntry(word: "Jara")]
        func fixModel(_ name: String) -> AppModel { makeModel(name, history: [fixItem], words: fixWords, healthy: true) }
        let pick = fixModel("fix-pick")
        ok = snapshot(pick, open: [pick.historyItems[0].id], fix: [pick.historyItems[0].id: .fixing(FixSelection(), typed: "")], to: "history-fix-pick") && ok
        let name = fixModel("fix-name")
        ok = snapshot(name, open: [name.historyItems[0].id], fix: [name.historyItems[0].id: .fixing(FixSelection(range: 3...3), typed: "")], to: "history-fix-name") && ok
        let everyday = fixModel("fix-everyday")
        ok = snapshot(everyday, open: [everyday.historyItems[0].id], fix: [everyday.historyItems[0].id: .fixing(FixSelection(range: 9...9), typed: "Jara")], to: "history-fix-everyday") && ok
        let saved = fixModel("fix-saved")
        if let result = saved.fixWord(in: saved.historyItems[0].id, words: 3...3, to: "Jyoti") {
            ok = snapshot(saved, open: [saved.historyItems[0].id], fix: [saved.historyItems[0].id: .saved(result)], to: "history-fix-saved") && ok
        } else { ok = false }

        // Someone who switched Accessibility and Input Monitoring on, and macOS still does not register them.
        let stuck = makeModel("stuck", history: [], words: starter, healthy: false)
        stuck.granted = [.microphone: true, .accessibility: false, .inputMonitoring: false]
        stuck.tried = [.accessibility, .inputMonitoring]
        stuck.modelStatus = .ready
        ok = snapshot(stuck, to: "first-run-stuck") && ok

        let emptyWords = makeModel("empty", history: items, words: [], healthy: true)
        emptyWords.tab = .words
        ok = snapshot(emptyWords, to: "words-empty") && ok

        exit(ok ? 0 : 1)
    }

    static func transcribe(path: String, useMyDictionary: Bool = false, pauses: Bool = true) -> Never {
        Task {
            do {
                let samples = try Resampler.samples(fromFile: URL(fileURLWithPath: path))
                let transcriber = Transcriber()
                let loadStart = Date()
                try await transcriber.load { _, _ in }
                let loadSeconds = Date().timeIntervalSince(loadStart)

                // The app stays running, so what matters is the speed after warm-up. Time five runs and report the middle one.
                var heard = Dictation(text: "", pieces: [])
                var timings: [Int] = []
                for _ in 0..<5 {
                    let start = Date()
                    heard = try await transcriber.dictate(samples, rules: PauseRules(enabled: pauses))
                    timings.append(Int(Date().timeIntervalSince(start) * 1000))
                }
                let raw = heard.text
                // How the recording was cut at pauses, for tuning the pause rules on a real voice.
                let pieces = heard.pieces.map { piece in
                    [
                        "from": (piece.start * 100).rounded() / 100,
                        "to": (piece.end * 100).rounded() / 100,
                        "silenceBefore": (piece.silenceBefore * 100).rounded() / 100,
                        "text": piece.text,
                    ] as [String: Any]
                }
                let ms = timings.sorted()[timings.count / 2]

                let cleaned = TextCleaner().clean(raw)
                // `--my-dictionary` tests against your real word list, with the same real-word guard the app uses.
                let corrector = useMyDictionary
                    ? DictionaryCorrector(entries: (try? AppFiles().loadDictionary()) ?? AppFiles.starterDictionary, isKnownWord: AppModel.isRealWord)
                    : DictionaryCorrector(entries: AppFiles.starterDictionary)
                let (text, corrections) = corrector.apply(to: cleaned)

                let result: [String: Any] = [
                    "text": text,
                    "raw": raw,
                    "corrections": corrections.map { ["heard": $0.heard, "written": $0.written] },
                    "audioSeconds": (Double(samples.count) / 16_000 * 100).rounded() / 100,
                    "transcribeMs": ms,
                    "allRunsMs": timings,
                    "pieces": pieces,
                    "modelLoadSeconds": (loadSeconds * 10).rounded() / 10,
                ]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
