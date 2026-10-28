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

        let rate = Double(Self.sampleRate)
        var pieces: [Dictation.Piece] = []
        var index = 0
        while index < segments.count {
            var segment = segments[index]
            var text = try await transcribe(Array(samples[segment.range]))
            // A piece that stops on "to" or "the" means the speaker was only thinking. Hear it together with what follows.
            while index + 1 < segments.count, SentenceJoiner.endsMidSentence(text) {
                index += 1
                segment = SpeechSegment(
                    range: segment.range.lowerBound..<segments[index].range.upperBound,
                    silenceBefore: segment.silenceBefore)
                text = try await transcribe(Array(samples[segment.range]))
            }
            pieces.append(Dictation.Piece(
                start: Double(segment.range.lowerBound) / rate, end: Double(segment.range.upperBound) / rate,
                silenceBefore: segment.silenceBefore, text: text))
            index += 1
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
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state).text
    }
}
