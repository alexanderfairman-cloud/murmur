import Foundation

/// Turns a spoken email address into a written one: "janedoe at gmail.com" becomes "janedoe@gmail.com".
///
/// The speech model already writes "dot" as a full stop ("gmail.com", "john.smith") but leaves the word "at" alone, and
/// leaves "underscore" and "dash" as words. This finishes the job, and only when the words around "at" really look like
/// an address, so "look at google.com" stays as it is.
public enum EmailFormatter {
    private static let symbols: [String: String] = [
        "dot": ".", "underscore": "_", "dash": "-", "hyphen": "-", "plus": "+",
    ]

    /// An address has to end in one of these. This is what keeps "at the dot" and similar talk from becoming an address.
    private static let endings: Set<String> = [
        "com", "org", "net", "edu", "gov", "mil", "int", "io", "co", "ai", "app", "dev", "me", "us", "uk", "ca", "au", "nz",
        "ie", "de", "fr", "es", "it", "nl", "be", "ch", "se", "no", "dk", "fi", "pt", "pl", "ru", "in", "jp", "cn",
        "kr", "br", "mx", "info", "biz", "xyz", "tv", "ly", "so", "sh", "gg", "cc", "fm", "tech", "online", "site", "store",
        "shop", "blog", "cloud", "agency", "studio", "design", "health", "life", "world", "today", "email", "group", "team",
        "global", "network", "media", "news", "link", "page", "one", "pro", "club", "live", "digital",
    ]

    /// Well-known mail providers, for when the ending was left off ("janedoe at gmail").
    private static let providers: [String: String] = [
        "gmail": "gmail.com", "yahoo": "yahoo.com", "hotmail": "hotmail.com", "outlook": "outlook.com",
        "icloud": "icloud.com", "aol": "aol.com", "protonmail": "protonmail.com", "proton": "proton.me",
        "live": "live.com", "msn": "msn.com",
    ]

    /// Words that, right before "at", show it is ordinary English ("look at", "meet me at", "email me at") and not
    /// the middle of an address. Names like "info" or "support" are deliberately not here: they are real addresses.
    private static let proseBeforeAt: Set<String> = [
        "me", "you", "him", "her", "us", "them", "it", "that", "this", "there", "here", "now", "home", "work", "school",
        "night", "noon", "once", "least", "most", "all", "look", "looks", "looked", "looking", "arrive", "arrived", "arriving",
        "meet", "meeting", "met", "available", "call", "called", "calling", "text", "texted", "stay",
        "stayed", "staying", "live", "lives", "living", "working", "wait", "waiting", "start", "started", "starting", "aimed",
        "glance", "glanced", "stare", "stared", "smile", "smiled", "laugh", "laughed", "good", "bad", "great", "best",
        "worst", "and", "or", "but", "the", "an", "of", "to", "in", "on", "for", "with", "by", "is", "are", "was", "were",
        "be", "been", "do", "does", "did", "have", "has", "had", "not", "no", "yes", "ok", "okay", "also", "just", "even", "only", "still", "maybe", "sorry",
        "shop", "shopped", "shopping", "buy", "bought", "buying", "order", "ordered", "found", "got", "saw", "read",
        "check", "checked", "go", "went", "going", "come", "came",
    ]

    private struct Piece {
        let range: Range<String.Index>
        /// Punctuation before the word, the word itself, and punctuation after it.
        let leading: String
        let core: String
        let trailing: String

        let coreRange: Range<String.Index>
    }

    public static func format(_ text: String) -> String {
        guard text.lowercased().contains(" at ") else { return text }
        let pieces = split(text)
        var replacements: [(range: Range<String.Index>, address: String)] = []
        var consumedThrough = -1

        for i in pieces.indices where pieces[i].core.lowercased() == "at" && pieces[i].leading.isEmpty && pieces[i].trailing.isEmpty {
            guard i >= 1, i + 1 < pieces.count, let local = parseLocal(pieces, before: i), local.first > consumedThrough,
                  let domain = parseDomain(pieces, after: i) ?? parseDomainSkippingStrayA(pieces, after: i)
                      ?? parseDomainWithSplitName(pieces, after: i)
            else { continue }
            let start = pieces[local.first].coreRange.lowerBound
            let end = pieces[domain.last].coreRange.upperBound
            replacements.append((start..<end, (local.text + "@" + domain.text).lowercased()))
            consumedThrough = domain.last
        }

        var result = text
        for replacement in replacements.reversed() { result.replaceSubrange(replacement.range, with: replacement.address) }
        return result
    }

    // MARK: - The part before "at"

    private static func parseLocal(_ pieces: [Piece], before at: Int) -> (text: String, first: Int)? {
        let previous = pieces[at - 1]
        // Punctuation right before "at" means a sentence or phrase ended there.
        guard previous.trailing.isEmpty, isNameLike(previous.core), !proseBeforeAt.contains(previous.core.lowercased()) else { return nil }
        var parts = [previous.core]
        var first = at - 1

        // "john dot smith" and "jane underscore doe": spoken symbols between name parts.
        while first >= 2 {
            let symbol = pieces[first - 1], before = pieces[first - 2]
            guard let mark = symbols[symbol.core.lowercased()], symbol.leading.isEmpty, symbol.trailing.isEmpty,
                  before.trailing.isEmpty, isNameLike(before.core)
            else { break }
            parts.insert(contentsOf: [before.core, mark], at: 0)
            first -= 2
        }

        // "j d doe": letters spelled out one at a time. (A lone "a" or "I" is a real word, so they do not count.)
        var letters = 0
        while first >= 1, letters < 4 {
            let letter = pieces[first - 1]
            guard letter.core.count == 1, letter.core.first?.isLetter == true,
                  !["a", "i"].contains(letter.core.lowercased()), letter.trailing.isEmpty || letter.trailing == "."
            else { break }
            parts.insert(letter.core, at: 0)
            first -= 1
            letters += 1
        }
        return (parts.joined(), first)
    }

    private static func isNameLike(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        return word.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._+-".unicodeScalars.contains($0) }
    }

    // MARK: - The part after "at"

    private static func parseDomain(_ pieces: [Piece], after at: Int) -> (text: String, last: Int)? {
        var labels: [String] = []
        var index = at + 1
        var expectLabel = true
        var last = at

        while index < pieces.count {
            let piece = pieces[index]
            if expectLabel {
                guard piece.leading.isEmpty || index == at + 1, isDomainPart(piece.core) else { break }
                labels.append(contentsOf: piece.core.split(separator: ".").map(String.init))
                last = index
                if !piece.trailing.isEmpty { break } // punctuation ends the address
                expectLabel = false
            } else if piece.core.lowercased() == "dot", piece.leading.isEmpty, piece.trailing.isEmpty {
                expectLabel = true
            } else {
                break
            }
            index += 1
        }
        // A spoken "dot" with nothing after it is not part of the address.
        guard last > at, !labels.isEmpty else { return nil }

        if labels.count >= 2, let ending = labels.last?.lowercased(), endings.contains(ending) {
            return (labels.joined(separator: "."), last)
        }
        // "janedoe at gmail": a well-known provider with the ending left off.
        if labels.count == 1, let full = providers[labels[0].lowercased()] { return (full, last) }
        return nil
    }

    /// "pat at a acmeco.com": the speech model sometimes hears a stray "a" after "at". Only tried when the
    /// words as they stand are not an address, so a spoken letter ("jane at a dot com") still counts as a letter.
    private static func parseDomainSkippingStrayA(_ pieces: [Piece], after at: Int) -> (text: String, last: Int)? {
        let stray = pieces[at + 1]
        guard stray.core.lowercased() == "a", stray.leading.isEmpty, stray.trailing.isEmpty, at + 2 < pieces.count else { return nil }
        return parseDomain(pieces, after: at + 1)
    }

    /// "pat at acme corp.com" or "pat at acme corp dot com": the speech model sometimes writes one company name as
    /// separate words. Up to three plain words (after a stray "a", if there is one) are joined into one word, and that
    /// is read as the start of the domain. Only tried when the words as they stand are not an address.
    private static func parseDomainWithSplitName(_ pieces: [Piece], after at: Int) -> (text: String, last: Int)? {
        var first = at + 1
        let lead = pieces[first]
        if first + 1 < pieces.count, lead.core.lowercased() == "a", lead.leading.isEmpty, lead.trailing.isEmpty { first += 1 }

        var end = first
        while end < pieces.count, end - first < 3 {
            let piece = pieces[end]
            guard piece.leading.isEmpty || end == first, isPlainWord(piece.core), piece.core.lowercased() != "dot" else { break }
            end += 1
            if !piece.trailing.isEmpty { break }
        }
        // A dotted word straight after them ("corp.com") is the end of the same name.
        if end > first, end < pieces.count, pieces[end - 1].trailing.isEmpty,
           pieces[end].leading.isEmpty, pieces[end].core.contains("."), isDomainPart(pieces[end].core) {
            end += 1
        }
        guard end - first >= 2 else { return nil }

        let name = Piece(
            range: pieces[first].range.lowerBound..<pieces[end - 1].range.upperBound,
            leading: pieces[first].leading,
            core: pieces[first..<end].map(\.core).joined(),
            trailing: pieces[end - 1].trailing,
            coreRange: pieces[first].coreRange.lowerBound..<pieces[end - 1].coreRange.upperBound)
        let merged = Array(pieces[...at]) + [name] + Array(pieces[end...])
        guard let result = parseDomain(merged, after: at) else { return nil }
        // Back to the numbering of the original words.
        return (result.text, result.last + (end - at - 2))
    }

    private static func isPlainWord(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
    }

    private static func isDomainPart(_ word: String) -> Bool {
        guard !word.isEmpty, !word.hasPrefix("."), !word.hasSuffix(".") else { return false }
        return word.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-.".unicodeScalars.contains($0) }
    }

    // MARK: - Splitting the text into words

    /// Splits at spaces and line breaks. Each piece keeps the punctuation at either end apart from the word, so
    /// "gmail.com." (end of a sentence) can be read as the word "gmail.com" and a full stop.
    private static func split(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isWhitespace {
                i = text.index(after: i)
                continue
            }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            var start = i, end = j
            while start < end, "\"'([{".contains(text[start]) { start = text.index(after: start) }
            while end > start, ".,;:!?)]}\"'".contains(text[text.index(before: end)]) { end = text.index(before: end) }
            pieces.append(Piece(
                range: i..<j, leading: String(text[i..<start]), core: String(text[start..<end]),
                trailing: String(text[end..<j]), coreRange: start..<end))
            i = j
        }
        return pieces
    }
}

/// Everything done to the speech model's words before the dictionary sees them.
public enum SpokenText {
    public static func tidy(_ raw: String, removeFillers: Bool = true) -> String {
        let cleaner = TextCleaner()
        let cleaned = removeFillers ? cleaner.clean(raw) : cleaner.trimmed(raw)
        return EmailFormatter.format(cleaned)
    }
}
