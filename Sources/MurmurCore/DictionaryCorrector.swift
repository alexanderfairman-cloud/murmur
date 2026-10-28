import Foundation

/// One word you want spelled a certain way, plus the wrong spellings the speech model tends to produce for it.
public struct DictionaryEntry: Codable, Equatable, Identifiable {
    public var word: String
    public var heardAs: [String]
    public var id: String { word }

    public init(word: String, heardAs: [String] = []) {
        self.word = word
        self.heardAs = heardAs
    }
}

/// A word the dictionary changed, kept so the history can show what was fixed.
public struct Correction: Codable, Equatable {
    public let heard: String
    public let written: String

    public init(heard: String, written: String) {
        self.heard = heard
        self.written = written
    }
}

/// Swaps misheard words for the spellings in your dictionary.
/// Three kinds of match, tried in this order for each stretch of up to four words:
/// 1. the dictionary word itself with different capitals or spacing ("super base" and "Supabase"),
/// 2. any "heard as" spelling you listed,
/// 3. a near miss (one or two letters off) of a longer word, but only when the heard word is not a real word.
public struct DictionaryCorrector {
    public var entries: [DictionaryEntry]
    private let isKnownWord: (String) -> Bool

    public init(entries: [DictionaryEntry], isKnownWord: @escaping (String) -> Bool = { _ in false }) {
        self.entries = entries
        self.isKnownWord = isKnownWord
    }

    private struct Token {
        let range: Range<String.Index>
        let text: String
        /// An email address or web link, kept whole: it is matched as one word and never respelled by fuzzy matching.
        var isAddress = false
    }

    private static let tokenPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)?"#)

    public func apply(to text: String) -> (text: String, corrections: [Correction]) {
        guard !entries.isEmpty else { return (text, []) }
        let tokens = Self.tokens(in: text)
        guard !tokens.isEmpty else { return (text, []) }

        var exact: [String: String] = [:]
        for entry in entries {
            exact[Self.normalize(entry.word)] = entry.word
            for heard in entry.heardAs { exact[Self.normalize(heard)] = entry.word }
        }
        let fuzzy = entries.compactMap { entry -> (key: String, word: String)? in
            let key = Self.normalize(entry.word)
            return key.count >= 6 ? (key, entry.word) : nil
        }

        var output = ""
        var cursor = text.startIndex
        var corrections: [Correction] = []
        var i = 0
        while i < tokens.count {
            var match: (count: Int, written: String)?
            for size in stride(from: min(4, tokens.count - i), through: 1, by: -1) {
                let window = Array(tokens[i..<(i + size)])
                let hasAddress = window.contains(where: \.isAddress)
                guard Self.onlySpacesBetween(window, in: text), !(hasAddress && size > 1) else { continue }
                let joined = Self.normalize(window.map(\.text).joined())
                if let written = exact[joined] {
                    match = (size, written)
                    break
                }
                if size <= 2, !hasAddress, !isKnownWord(joined), let written = Self.nearest(joined, in: fuzzy) {
                    match = (size, written)
                    break
                }
            }
            guard let hit = match else {
                i += 1
                continue
            }
            let start = tokens[i].range.lowerBound
            let end = tokens[i + hit.count - 1].range.upperBound
            output += text[cursor..<start]
            let heard = String(text[start..<end])
            let written = Self.withSentenceCapital(hit.written, heard: heard, startingAt: start, in: text)
            if heard != written { corrections.append(Correction(heard: heard, written: written)) }
            output += written
            cursor = end
            i += hit.count
        }
        output += text[cursor...]
        return (output, corrections)
    }

    // MARK: - Helpers

    private static let addressPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}|(?:https?://|www\.)[^\s]+"#)

    /// Email addresses and web links. Words inside them are never changed on their own ("alex@gmail.com" must not
    /// become "Alex@gmail.com"), but a whole address can be a saved word, so a misheard one can be corrected.
    private static func addressesAndLinks(in text: String) -> [Range<String.Index>] {
        addressPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// A word saved in all lowercase has no capital of its own, so it must not force one away or add one:
    /// if the model already wrote it the same way apart from capitals, that is left alone, and otherwise it is
    /// written in lowercase, except at the start of a sentence where it gets its capital.
    private static func withSentenceCapital(
        _ written: String, heard: String, startingAt start: String.Index, in text: String
    ) -> String {
        guard !written.contains("@"), written == written.lowercased(), written.contains(where: \.isLetter) else { return written }
        if heard.lowercased() == written { return heard }
        guard startsSentence(at: start, in: text), let first = written.first else { return written }
        return first.uppercased() + written.dropFirst()
    }

    private static func startsSentence(at index: String.Index, in text: String) -> Bool {
        var i = index
        while i > text.startIndex {
            let c = text[text.index(before: i)]
            if c == " " || c == "\t" || "\"'\u{201C}\u{2018}(".contains(c) {
                i = text.index(before: i)
                continue
            }
            return c.isNewline || ".!?".contains(c)
        }
        return true
    }

    /// Words, with each email address or link joined into a single token.
    private static func tokens(in text: String) -> [Token] {
        let wholes = addressesAndLinks(in: text)
        var result: [Token] = []
        for m in tokenPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            if let whole = wholes.first(where: { $0.overlaps(r) }) {
                if result.last?.range != whole {
                    result.append(Token(range: whole, text: String(text[whole]), isAddress: true))
                }
            } else {
                result.append(Token(range: r, text: String(text[r])))
            }
        }
        return result
    }

    private static func onlySpacesBetween(_ window: [Token], in text: String) -> Bool {
        for (a, b) in zip(window, window.dropFirst()) {
            let gap = text[a.range.upperBound..<b.range.lowerBound]
            if gap.isEmpty || !gap.allSatisfy({ $0 == " " || $0 == "\t" }) { return false }
        }
        return true
    }

    /// Lowercase letters and digits only, so "Next.js", "next js" and "NextJS" all compare equal.
    static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func nearest(_ heard: String, in candidates: [(key: String, word: String)]) -> String? {
        var best: (distance: Int, word: String)?
        for c in candidates {
            guard heard.first == c.key.first, abs(heard.count - c.key.count) <= 2 else { continue }
            let allowed = c.key.count >= 9 ? 2 : 1
            let d = editDistance(heard, c.key)
            if d <= allowed, d < (best?.distance ?? Int.max) { best = (d, c.word) }
        }
        return best?.word
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
