import CoreML
import FluidAudio
import Foundation
import MurmurCore

enum TranscriberError: Error, LocalizedError {
    case notReady
    var errorDescription: String? { "The speech model is not ready yet." }
}

/// The words of one dictation, and how the recording was cut up to get them.
struct Dictation {
    struct Piece {
        let start: Double
        let end: Double
        let silenceBefore: Double
        let text: String
    }

    let text: String
    /// Empty when the recording had no long pause and went to the model in one go.
    let pieces: [Piece]
}

/// Turns audio into words using NVIDIA's Parakeet model, which runs on the Mac's own chip.
/// The first run downloads the model (about half a gigabyte); after that it works with no internet.
actor Transcriber {
    /// English-only. It is the most accurate Parakeet for English.
    private static let version: AsrModelVersion = .v2
    private static let sampleRate = SilenceSplitter.sampleRate

    private var manager: AsrManager?

    var isReady: Bool { manager != nil }

    /// How much work the speech model has done: runs, and seconds of audio fed to it. A check can count the work a recording
    /// costs, which does not wobble with how busy the Mac is the way a stopwatch does.
    private(set) var modelRuns = 0
    private(set) var modelSeconds = 0.0

    /// `progress` is told the fraction done (0 to 1) and whether we are in the download step.
    func load(progress: @escaping @Sendable (_ fraction: Double, _ downloading: Bool) -> Void) async throws {
        guard manager == nil else { return }
        let models = try await AsrModels.downloadAndLoad(
            version: Self.version,
            // The graphics chip runs this model about 4x faster than the Neural Engine on an M2 Pro (120 ms against 600 ms).
            encoderComputeUnits: .cpuAndGPU,
            progressHandler: { p in
                if case .downloading = p.phase {
                    progress(p.fractionCompleted, true)
                } else {
                    progress(p.fractionCompleted, false)
                }
            }
        )
        // One chunk at a time. By default the library runs four chunks of a long recording at once on the same model,
        // and a crash report showed three threads inside Core ML together when Murmur aborted (a rare event on long dictations).
        let asr = AsrManager(config: ASRConfig(parallelChunkConcurrency: 1))
        try await asr.loadModels(models)
        manager = asr
        // One throwaway run so the first real dictation is as fast as every later one.
        _ = try? await transcribe(Array(repeating: Float(0), count: Self.sampleRate))
    }

    /// Turns a recording into text. A recording with long pauses is cut at them, each piece is transcribed as its own
    /// sentence, and the pieces are joined with full stops and blank lines. The model is good at ending a sentence
    /// when it is handed one, and it cannot hear a pause inside a long recording.
    func dictate(_ samples: [Float], rules: PauseRules) async throws -> Dictation {
        let segments = rules.enabled ? SilenceSplitter(minimumPause: rules.sentencePause).split(samples) : []
        guard segments.count > 1 else {
            return Dictation(text: try await transcribe(samples), pieces: [])
        }

        // Every piece is heard alone, with the quiet on each side of it (half of each pause). Cutting that quiet away saves model
        // time but costs commas: "First, we need" becomes "First we need", because the model uses the quiet to hear where a phrase ends.
        let rate = Double(Self.sampleRate)
        var alone: [String] = []
        for segment in segments { alone.append(try await transcribe(Array(samples[segment.range]))) }

        // Pieces that cannot end a sentence where they stop ("an event is simply", "because to me"), or that cannot start one
        // ("of the plan"), mean the speaker was only thinking (see SentenceCompleteness). Each such run of pieces is heard once
        // more, all together, with the long pauses squeezed short, so the model writes one sentence instead of a full stop at each
        // pause. One extra listen per run, however many pieces it has.
        var pieces: [Dictation.Piece] = []
        for run in SentenceCompleteness.runs(of: alone) {
            let first = segments[run.lowerBound], last = segments[run.upperBound - 1]
            let text = run.count == 1
                ? alone[run.lowerBound]
                : try await transcribe(SilenceSplitter.stitch(samples, run.map { segments[$0].speech }))
            pieces.append(Dictation.Piece(
                start: Double(first.range.lowerBound) / rate, end: Double(last.range.upperBound) / rate,
                silenceBefore: first.silenceBefore, text: text))
        }
        let joined = SentenceJoiner.join(pieces.map { ($0.text, $0.silenceBefore) }, paragraphPause: rules.paragraphPause)
        return Dictation(text: joined, pieces: pieces)
    }

    private func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw TranscriberError.notReady }
        // The model wants at least one second of audio.
        var audio = samples
        if audio.count < Self.sampleRate {
            audio.append(contentsOf: repeatElement(0, count: Self.sampleRate - audio.count))
        }
        modelRuns += 1
        modelSeconds += Double(audio.count) / Double(Self.sampleRate)
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state).text
    }
}
