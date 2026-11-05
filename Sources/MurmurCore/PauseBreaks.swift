import Foundation

/// How long a silence has to be before Murmur treats it as the end of a sentence, or of a paragraph.
/// These are first guesses (people pause for different lengths); both can be changed in settings.json.
public struct PauseRules: Equatable {
    public var enabled: Bool
    /// Seconds of quiet that end a sentence.
    public var sentencePause: Double
    /// Seconds of quiet that start a new paragraph.
    public var paragraphPause: Double

    public init(enabled: Bool = true, sentencePause: Double = 0.8, paragraphPause: Double = 1.8) {
        self.enabled = enabled
        self.sentencePause = sentencePause
        self.paragraphPause = paragraphPause
    }
}

/// A stretch of speech between two long silences, as a range of sample positions in the recording.
public struct SpeechSegment: Equatable {
    public let range: Range<Int>
    /// Just the talking in `range`, with a little padding: without the quiet that `range` keeps on each side.
    public let speech: Range<Int>
    /// How long the silence just before this piece was, in seconds. Zero for the first piece.
    public let silenceBefore: Double

    public init(range: Range<Int>, speech: Range<Int>? = nil, silenceBefore: Double) {
        self.range = range
        self.speech = speech ?? range
        self.silenceBefore = silenceBefore
    }
}

/// Finds the real silences in a recording by measuring how loud it is, 100 times a second.
/// The speech model's own word timings are too rough to find a pause (they can be a whole word out),
/// so the audio is measured directly.
public struct SilenceSplitter {
    public static let sampleRate = 16_000
    private static let frameSamples = 160 // 10 milliseconds
    private static let frameSeconds = 0.01
    /// Quiet kept on each side of the speech, so the start of the first word and the end of the last are not clipped.
    private static let paddingFrames = 15

    public var minimumPause: Double

    public init(minimumPause: Double = 0.8) {
        self.minimumPause = minimumPause
    }

    /// Cuts the recording at every silence of `minimumPause` seconds or more. Quiet at the very start and end is dropped.
    /// A recording with no such silence comes back as one piece, and one with no speech at all as none.
    public func split(_ samples: [Float]) -> [SpeechSegment] {
        let loudness = Self.loudness(of: samples)
        guard !loudness.isEmpty else { return [] }

        // "Quiet" is judged against this recording: a little above its own background noise,
        // and well below its own speech level. That works in a silent room and in a noisy one.
        let ordered = loudness.sorted()
        let noiseFloor = max(ordered[ordered.count / 10], 0.0005)
        let speechLevel = ordered[ordered.count * 9 / 10]
        let threshold = max(noiseFloor * 2.5, speechLevel * 0.05)
        let isSpeech = loudness.map { $0 >= threshold }
        guard let first = isSpeech.firstIndex(of: true), let last = isSpeech.lastIndex(of: true) else { return [] }

        var silences: [(start: Int, end: Int)] = []
        var runStart: Int?
        for i in first...last {
            if !isSpeech[i] {
                if runStart == nil { runStart = i }
            } else if let start = runStart {
                if Double(i - start) * Self.frameSeconds >= minimumPause { silences.append((start, i)) }
                runStart = nil
            }
        }

        let total = samples.count
        var segments: [SpeechSegment] = []
        var pieceStart = max(0, first - Self.paddingFrames)
        var speechStart = first
        var silenceBefore = 0.0
        for silence in silences {
            let middle = (silence.start + silence.end) / 2
            let speechFrom = max(pieceStart, speechStart - Self.paddingFrames)
            let speechTo = min(middle, silence.start + Self.paddingFrames)
            segments.append(SpeechSegment(
                range: pieceStart * Self.frameSamples..<min(middle * Self.frameSamples, total),
                speech: speechFrom * Self.frameSamples..<min(speechTo * Self.frameSamples, total),
                silenceBefore: silenceBefore))
            pieceStart = middle
            speechStart = silence.end
            silenceBefore = Double(silence.end - silence.start) * Self.frameSeconds
        }
        let end = min((last + 1 + Self.paddingFrames) * Self.frameSamples, total)
        let speechFrom = max(pieceStart, speechStart - Self.paddingFrames)
        segments.append(SpeechSegment(
            range: pieceStart * Self.frameSamples..<end,
            speech: speechFrom * Self.frameSamples..<end,
            silenceBefore: silenceBefore))
        return segments
    }

    /// The talking of several pieces joined with only `gap` seconds of quiet between them.
    /// Used when a long pause turned out to be the speaker thinking: the speech model then hears one unbroken phrase
    /// and does not write a full stop at a pause that is no longer there.
    public static func stitch(_ samples: [Float], _ ranges: [Range<Int>], gap: Double = 0.25) -> [Float] {
        let spacer = [Float](repeating: 0, count: Int(gap * Double(sampleRate)))
        var joined: [Float] = []
        for (i, range) in ranges.enumerated() {
            if i > 0 { joined += spacer }
            joined += samples[range]
        }
        return joined
    }

    private static func loudness(of samples: [Float]) -> [Float] {
        stride(from: 0, to: samples.count - frameSamples + 1, by: frameSamples).map { start in
            var sum: Float = 0
            for i in start..<start + frameSamples { sum += samples[i] * samples[i] }
            return (sum / Float(frameSamples)).squareRoot()
        }
    }
}

/// Puts the separately transcribed pieces back together as sentences and paragraphs.
public enum SentenceJoiner {
    /// True when the text stops in the middle of a sentence. See `SentenceCompleteness`.
    public static func endsMidSentence(_ text: String) -> Bool {
        SentenceCompleteness.isUnfinished(text)
    }

    /// Joins pieces with a space, or with a blank line when the silence before a piece was `paragraphPause` seconds or more.
    /// Every piece that has another after it is closed with a full stop if the model left it open or ended it with a comma.
    public static func join(_ pieces: [(text: String, silenceBefore: Double)], paragraphPause: Double) -> String {
        var result = ""
        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if result.isEmpty {
                result = text
            } else {
                let separator = piece.silenceBefore >= paragraphPause ? "\n\n" : " "
                result = closed(result) + separator + capitalizingFirstLetter(text)
            }
        }
        return result
    }

    private static func closed(_ text: String) -> String {
        guard let last = text.last else { return text }
        if ".!?".contains(last) || last == "\u{2026}" { return text }
        if ",;:".contains(last) { return String(text.dropLast()) + "." }
        return text + "."
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}
