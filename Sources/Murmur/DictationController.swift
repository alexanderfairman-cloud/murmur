import AppKit
import AVFoundation
import MurmurCore
import os

enum ModelStatus {
    case ready
    case loading(fraction: Double, downloading: Bool)
    case failed
}

/// Runs one dictation from key press to typed text: listen, transcribe, clean up, type, remember.
@MainActor
final class DictationController {
    enum Phase: Equatable {
        case idle
        case recording(locked: Bool)
        /// The key came up; listening for a split second longer so the last word is not clipped.
        case finishing
    }

    private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    var onPhaseChange: ((Phase) -> Void)?
    var onHistoryChange: (() -> Void)?
    private(set) var lastText: String?

    private let recorder = AudioRecorder()
    private let transcriber: Transcriber
    private let hud: HUDController
    private let history: HistoryStore
    private let settings: () -> Settings
    private let corrector: () -> DictionaryCorrector
    private let modelStatus: () -> ModelStatus
    private let log = Logger(subsystem: "com.jamesseriph.murmur", category: "dictation")

    private var autoStop: Task<Void, Never>?
    private var recordingStartedAt = Date()
    private var jobs: Task<Void, Never>?

    /// Past this length a forgotten hands-free recording stops by itself.
    private static let longestRecording: Duration = .seconds(600)
    /// Shorter than this is an accidental tap, not speech.
    private static let shortestSpeech = 0.3
    /// Quieter than this (about -40 dB) is silence or a muted microphone.
    private static let silenceFloor: Float = 0.01

    init(
        transcriber: Transcriber, hud: HUDController, history: HistoryStore,
        settings: @escaping () -> Settings,
        corrector: @escaping () -> DictionaryCorrector,
        modelStatus: @escaping () -> ModelStatus
    ) {
        self.transcriber = transcriber
        self.hud = hud
        self.history = history
        self.settings = settings
        self.corrector = corrector
        self.modelStatus = modelStatus
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    // MARK: - What the keys do

    func keyPressed() {
        switch phase {
        case .idle: begin()
        case .recording(let locked): if locked { finish() }
        case .finishing: break
        }
    }

    func keyReleased() {
        if case .recording(locked: false) = phase { finish() }
    }

    /// For the menu: click once to start, again to stop.
    func toggle() {
        switch phase {
        case .idle: begin()
        case .recording: finish()
        case .finishing: break
        }
    }

    /// Fn + Space: keep listening after the key comes up. True if the lock was taken.
    func lock() -> Bool {
        guard case .recording(locked: false) = phase else { return false }
        phase = .recording(locked: true)
        hud.listening(locked: true)
        return true
    }

    /// Another key was pressed along with the dictation key, so it was a shortcut (like Fn + arrow), not dictation.
    func cancelShortcut() {
        if case .recording(locked: false) = phase { cancel() }
    }

    /// Escape: throw the recording away. True if there was one.
    @discardableResult
    func cancel() -> Bool {
        guard case .recording = phase else { return false }
        autoStop?.cancel()
        recorder.stop()
        phase = .idle
        hud.hide()
        return true
    }

    /// Command + Control + V: type the last dictation again. True if there was one.
    func pasteLast() -> Bool {
        guard let text = lastText ?? history.items.first?.text else { return false }
        Task { _ = await TextInjector.insert(text) }
        return true
    }

    // MARK: - One dictation

    private func begin() {
        switch modelStatus() {
        case .ready: break
        case .loading(let fraction, let downloading):
            if downloading { hud.progress(fraction) } else { hud.message("Starting up. One moment") }
            return
        case .failed:
            hud.message("The speech model could not load. Check your internet and restart Murmur", seconds: 5)
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            hud.message("Allow the microphone, then hold the key again", seconds: 4)
            return
        default:
            hud.message("The microphone is off for Murmur. Turn it on in System Settings", seconds: 5)
            return
        }

        recorder.onLevel = { [weak self] rms in
            Task { @MainActor in self?.hud.level(rms) }
        }
        let microphone: String
        do {
            microphone = try recorder.start(preferBuiltIn: settings().preferBuiltInMicrophone)
        } catch {
            log.error("could not start the microphone: \(error.localizedDescription)")
            hud.message("No microphone found")
            return
        }
        recordingStartedAt = Date()
        log.info("listening with \(microphone, privacy: .public)")
        play(.start)
        phase = .recording(locked: false)
        hud.listening(locked: false)
        autoStop = Task { [weak self] in
            try? await Task.sleep(for: Self.longestRecording)
            if !Task.isCancelled { self?.finish() }
        }
    }

    private func finish() {
        guard case .recording = phase else { return }
        autoStop?.cancel()
        phase = .finishing
        hud.thinking()
        let frontApp = NSWorkspace.shared.frontmostApplication
        let app = frontApp?.localizedName
        let appID = frontApp?.bundleIdentifier
        let heldFor = Date().timeIntervalSince(recordingStartedAt)
        let microphone = recorder.microphoneName
        Task { [weak self] in
            // Keep listening a moment longer so the last word is not clipped.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            let samples = self.recorder.stop()
            self.phase = .idle
            self.play(.stop)
            self.enqueue { await self.process(samples, app: app, appID: appID, heldFor: heldFor, microphone: microphone) }
        }
    }

    /// Dictations are typed in the order you spoke them, even if one takes longer than the next.
    private func enqueue(_ job: @escaping @MainActor () async -> Void) {
        let previous = jobs
        jobs = Task { @MainActor in
            await previous?.value
            await job()
        }
    }

    private func process(_ samples: [Float], app: String?, appID: String?, heldFor: TimeInterval, microphone: String) async {
        let seconds = Double(samples.count) / 16_000
        // The key was held but not one sound arrived: the microphone is not delivering (a Bluetooth headset can do this).
        if samples.isEmpty, heldFor >= 0.5 {
            log.error("no sound arrived from \(microphone, privacy: .public) in \(heldFor, format: .fixed(precision: 1)) s")
            tell("No sound from \(microphone). Check Sound settings.", seconds: 7)
            return
        }
        guard seconds >= Self.shortestSpeech else {
            log.info("ignored a recording of \(seconds, format: .fixed(precision: 2)) s")
            hideIfIdle()
            return
        }
        let peak = samples.map { abs($0) }.max() ?? 0
        guard peak >= Self.silenceFloor else {
            log.info("heard only silence from \(microphone, privacy: .public) (loudest \(peak, format: .fixed(precision: 4)))")
            tell("Didn't hear anything from \(microphone)")
            return
        }
        let started = Date()
        do {
            let dictation = try await transcriber.dictate(samples, rules: settings().pauseRules)
            let raw = dictation.text
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let cleaned = SpokenText.tidy(raw, removeFillers: settings().removeFillers)
            let (text, corrections) = corrector().apply(to: cleaned)
            guard !text.isEmpty else {
                tell("Didn't catch that")
                return
            }
            let typed = settings().trailingSpace ? text + " " : text
            let pasted = await TextInjector.insert(typed)
            lastText = text
            history.append(HistoryItem(
                text: text, rawText: raw, audioSeconds: seconds, transcribeMs: ms, app: app, appID: appID,
                corrections: corrections))
            onHistoryChange?()
            if pasted {
                hideIfIdle()
            } else {
                tell("Copied. Turn on Accessibility so Murmur can type it for you", seconds: 5)
            }
            log.info("dictated \(seconds, format: .fixed(precision: 1)) s of audio in \(ms) ms, \(max(dictation.pieces.count, 1)) piece(s), typed=\(pasted)")
        } catch {
            log.error("transcription failed: \(error.localizedDescription)")
            tell("Something went wrong. Try again")
        }
    }

    // MARK: - Small helpers

    /// Messages never cover a recording that has already started again.
    private func tell(_ text: String, seconds: Double = 2.6) {
        if phase == .idle { hud.message(text, seconds: seconds) }
    }

    private func hideIfIdle() {
        if phase == .idle { hud.hide() }
    }

    private enum Cue { case start, stop }

    private func play(_ cue: Cue) {
        guard settings().sounds else { return }
        let name = cue == .start ? "Tink" : "Pop"
        guard let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }
}
