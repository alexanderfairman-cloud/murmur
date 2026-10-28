import Foundation

/// The words of a dictation as the "Fix a word" screen shows them: split at spaces and line breaks, each word
/// kept apart from the punctuation around it, so fixing "her," gives "Jara," and not "Jara".
public struct FixTokens {
    public struct Token: Equatable {
        /// As typed, for example "Enneagram,".
        public let text: String
        /// Just the word: "Enneagram".
        public let core: String
        /// Line breaks in the whitespace just before this token. Zero means it is on the same line.
        public let lineBreaksBefore: Int
        fileprivate let coreRange: Range<String.Index>
    }

    public let text: String
    public let tokens: [Token]

    public init(_ text: String) {
        self.text = text
        var found: [Token] = []
        var i = text.startIndex
        var breaks = 0
        while i < text.endIndex {
            if text[i].isWhitespace {
                if text[i].isNewline { breaks += 1 }
                i = text.index(after: i)
                continue
            }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            let whole = i..<j
            // The word is the token without punctuation at either end. Inside it (Next.js, don't) is left alone.
            var start = whole.lowerBound, end = whole.upperBound
            while start < end, !Self.isPartOfWord(text[start]) { start = text.index(after: start) }
            while end > start, !Self.isPartOfWord(text[text.index(before: end)]) { end = text.index(before: end) }
            let core = start < end ? start..<end : whole
            found.append(Token(text: String(text[whole]), core: String(text[core]), lineBreaksBefore: breaks, coreRange: core))
            breaks = 0
            i = j
        }
        tokens = found
    }

    private static func isPartOfWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// What the speech model heard for these tokens, without the punctuation around it ("Jodi", "play right").
    public func heard(_ range: ClosedRange<Int>) -> String {
        guard let range = clamped(range) else { return "" }
        return tokens[range].map(\.core).joined(separator: " ")
    }

    /// The text with those tokens replaced by `word`. The punctuation outside the chosen words stays where it was.
    /// `range` says where the new word sits in the returned text, counted in characters.
    public func replacing(_ range: ClosedRange<Int>, with word: String) -> (text: String, range: Range<Int>)? {
        guard let range = clamped(range) else { return nil }
        let first = tokens[range.lowerBound].coreRange.lowerBound
        let last = tokens[range.upperBound].coreRange.upperBound
        let offset = text.distance(from: text.startIndex, to: first)
        return (String(text[..<first]) + word + String(text[last...]), offset..<(offset + word.count))
    }

    /// True when the single chosen word is an ordinary word, which makes a "heard as" rule risky: it would
    /// change every use of that word. A word the model capitalised in the middle of a sentence is treated as a
    /// name, since the model already thought it was one.
    public func looksLikeEverydayWord(_ range: ClosedRange<Int>, isRealWord: (String) -> Bool) -> Bool {
        guard let range = clamped(range), range.count == 1 else { return false }
        let word = tokens[range.lowerBound].core
        guard isRealWord(word.lowercased()) else { return false }
        if word.first?.isUppercase == true {
            let atSentenceStart = range.lowerBound == 0
                || tokens[range.lowerBound].lineBreaksBefore > 0
                || ".!?".contains(tokens[range.lowerBound - 1].text.last ?? " ")
            // Capitalised in the middle of a sentence: the model took it for a name.
            if !atSentenceStart { return false }
        }
        return true
    }

    private func clamped(_ range: ClosedRange<Int>) -> ClosedRange<Int>? {
        guard !tokens.isEmpty, range.lowerBound >= 0, range.upperBound < tokens.count else { return nil }
        return range
    }
}

/// Which words are chosen. Tapping a word chooses it; tapping a neighbour widens the choice up to four words.
public struct FixSelection: Equatable {
    public static let maxWords = 4
    public private(set) var range: ClosedRange<Int>?

    public init(range: ClosedRange<Int>? = nil) {
        self.range = range
    }

    public mutating func tap(_ i: Int) {
        guard let r = range else {
            range = i...i
            return
        }
        if r.contains(i) {
            range = i...i
        } else if i == r.lowerBound - 1, r.count < Self.maxWords {
            range = i...r.upperBound
        } else if i == r.upperBound + 1, r.count < Self.maxWords {
            range = r.lowerBound...i
        } else {
            range = i...i
        }
    }

    /// A word next to the choice that tapping would add to it.
    public func isNeighbor(_ i: Int) -> Bool {
        guard let r = range, !r.contains(i), r.count < Self.maxWords else { return false }
        return i == r.lowerBound - 1 || i == r.upperBound + 1
    }
}

/// What a fix changed, for the confirmation line and for showing the corrected text.
public struct FixResult: Equatable {
    public let heard: String
    /// The spelling now used, which is the Words spelling when the word already existed.
    public let written: String
    public let createdWord: Bool
    /// False when only capitals differed, so Words needed no new wrong spelling.
    public let ruleAdded: Bool
    public let newText: String
    /// Where the corrected word sits in `newText`, in characters.
    public let range: Range<Int>

    public init(heard: String, written: String, createdWord: Bool, ruleAdded: Bool, newText: String, range: Range<Int>) {
        self.heard = heard
        self.written = written
        self.createdWord = createdWord
        self.ruleAdded = ruleAdded
        self.newText = newText
        self.range = range
    }
}

extension WordList {
    /// Records that `heard` is a wrong spelling of `word`. If another word already claimed that spelling it is
    /// taken from it, because the person's latest decision is the one that counts. False when nothing changed.
    @discardableResult
    public mutating func claim(_ raw: String, for word: String) -> Bool {
        let heard = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !heard.isEmpty else { return false }
        var changed = false
        for entry in entries where entry.word.caseInsensitiveCompare(word) != .orderedSame && entry.heardAs.contains(heard) {
            removeHeardAs(heard, from: entry.word)
            changed = true
        }
        return addHeardAs(heard, to: word) || changed
    }

    /// Words to offer while someone types the right word. With nothing typed yet, the words that look most like
    /// what was heard; once they type, the words that start with it.
    public func suggestions(heard: String, typed: String, limit: Int = 3) -> [String] {
        let h = heard.lowercased()
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !t.isEmpty {
            return entries.map(\.word).filter { $0.lowercased().hasPrefix(t) && $0.lowercased() != t }.prefix(limit).map { $0 }
        }
        return entries.map(\.word)
            .map { ($0, DictionaryCorrector.editDistance(h, $0.lowercased())) }
            .filter { $0.1 <= 3 && $0.1 > 0 }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }
}
