import Foundation

/// The speech model sometimes ends a sentence in the middle of a thought, as "an event is simply. An occurrence that has
/// a timestamp on it." A sentence that cannot end where it stops (see `SentenceCompleteness`) is joined to the one after it:
/// a clause with no verb or a condition with no second half always, and one that stops on a word like "to" or "simply" only
/// when the next sentence does not start a new thought of its own ("I", "so", "and"), because a real sentence can end on
/// "the services we are hooked up to." A condition takes a comma; anything else takes a space, and the next word loses its
/// capital letter unless it is "I", an acronym or the name of a day or month.
/// Only full stops on the same line are touched: a blank line is a real pause and stays, and so do "?" and "!".
public enum SentenceRepair {
    private static let boundary = try! NSRegularExpression(pattern: #"(?<=\.) (?=[A-Z])"#)
    /// Words that open a thought of their own: each opened at least 25 real sentences and was under 2.5 times as likely to follow a
    /// mid-sentence cut as to open a sentence. A sentence that starts with one is not the rest of the one before it.
    private static let newThought: Set<String> = [
        "i", "we", "the", "this", "it", "let's", "please", "i'm", "also", "okay", "it's", "can", "in", "if", "for",
        "i'd", "you", "that", "now", "just", "that's", "we're", "what", "hey", "there", "they", "great", "yeah",
        "when", "so", "then", "i've", "is", "as", "i'll", "maybe", "there's", "first", "these", "go", "yes", "all",
        "let", "right", "thank", "do", "how", "currently", "my", "each", "on", "make", "however", "we'll", "one",
        "are", "thanks", "those", "he", "but", "what's", "at", "given", "again", "before", "ok", "ultimately",
        "while", "regarding", "once", "people", "here", "they're", "we've", "after", "really", "don't", "give", "our",
        "therefore", "everything", "would", "here's", "even", "why", "he's", "every", "she", "does",
        "remember", "some", "instead", "looking", "keep", "obviously", "remove", "finally", "by", "based",
        "hello", "try", "secondly", "hi", "you're", "use", "because", "we'd", "alright", "explain",
        "actually", "think", "your", "sorry", "most", "help", "another",
        "no", "essentially", "although", "looks", "overall", "add",
        // Spoken openers the counts miss, because they also open real continuations:
        "and", "but", "like",
    ]
    private static let alwaysCapital: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april",
        "may", "june", "july", "august", "september", "october", "november", "december",
    ]

    public static func apply(_ text: String) -> String {
        text.components(separatedBy: "\n").map(repairLine).joined(separator: "\n")
    }

    private static func repairLine(_ line: String) -> String {
        let breaks = boundary.matches(in: line, range: NSRange(line.startIndex..., in: line))
        guard !breaks.isEmpty else { return line }
        var sentences: [String] = []
        var from = line.startIndex
        for match in breaks {
            guard let space = Range(match.range, in: line) else { continue }
            sentences.append(String(line[from..<space.lowerBound]))
            from = space.upperBound
        }
        sentences.append(String(line[from...]))

        var before = ""
        var current = sentences[0]
        for next in sentences.dropFirst() {
            // Trailing dots ("we all...") are a hesitation the speaker meant to show: leave them.
            let trailing = current.hasSuffix("..") || current.hasSuffix("\u{2026}")
            if !trailing, SentenceCompleteness.isDanglingClause(current)
                || (SentenceCompleteness.endsOnCertainWord(current) && !opensNewThought(next)) {
                let open = SentenceCompleteness.endsOnOpenCondition(current)
                current = String(current.dropLast()) + (open ? ", " : " ") + lowercasingFirstWord(next)
            } else {
                before += current + " "
                current = next
            }
        }
        return before + current
    }

    private static func opensNewThought(_ sentence: String) -> Bool {
        let first = sentence.prefix(while: { $0.isLetter || $0 == "'" || $0 == "\u{2019}" })
        return newThought.contains(first.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"))
    }

    private static func lowercasingFirstWord(_ sentence: String) -> String {
        let word = sentence.prefix(while: { !$0.isWhitespace })
        let plain = word.filter { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }
        if plain == "I" || plain.hasPrefix("I'") || plain.hasPrefix("I\u{2019}") { return sentence }
        if plain.dropFirst().contains(where: { $0.isUppercase }) || alwaysCapital.contains(plain.lowercased()) { return sentence }
        guard let first = sentence.first else { return sentence }
        return first.lowercased() + sentence.dropFirst()
    }
}
