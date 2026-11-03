import Foundation

/// Says "comma" or "period" out loud and you get the mark, not the word:
/// "great to see you, comma, hoping we can meet" becomes "great to see you, hoping we can meet",
/// and "an amazing idea, period. Let's get together" becomes "an amazing idea. Let's get together".
///
/// The speech model writes its own commas and full stops around the word ("you, comma, hoping", "idea, period. Let's"),
/// so those are removed and replaced by the one mark you asked for. After a period the next word gets a capital letter.
/// Both words are also ordinary nouns ("a trial period", "an Oxford comma"), so a word that follows a word like "a", "the",
/// "trial" or "Oxford" is left as written, unless the model put a mark right before it (a spoken command always has one).
public enum SpokenPunctuation {
    private static let command = try! NSRegularExpression(
        // Not part of a longer word: "commas", "comma-separated" and "period's" are never commands.
        pattern: #"(?<![\p{L}\p{N}'’-])(comma|period)(?![\p{L}\p{N}'’-])"#, options: [.caseInsensitive])

    /// A word right before "comma" or "period" that makes it a noun ("a period", "this period", "Oxford comma", "the word comma").
    private static let nounLeaders: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "our", "their", "his", "her", "its",
        "one", "each", "every", "any", "another", "no", "some", "same", "such", "next", "last", "first", "second", "final",
        "whole", "entire", "certain", "given", "particular", "specific", "long", "short", "brief", "trial", "grace",
        "waiting", "probation", "cooling", "notice", "billing", "reporting", "payment", "initial", "transition", "free",
        "time", "oxford", "serial", "missing", "extra", "word", "called", "say", "said", "says", "saying", "type", "typed",
        "typing", "of", "for", "in", "during", "over", "within", "after", "before", "by", "at", "into", "through", "per",
    ]

    /// "a period of time", "a period when", "the period between": the next word shows the noun.
    private static let periodFollowers: Set<String> = ["of", "when", "between"]

    public static func apply(_ text: String) -> String {
        var result = text
        // Walk backwards so earlier positions stay valid while the text changes.
        for match in command.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let word = Range(match.range, in: result) else { continue }
            let isPeriod = result[word].lowercased() == "period"

            // What is just before: any commas, full stops and spaces the model wrote there are dropped.
            var headEnd = word.lowerBound
            var markBefore = false
            while headEnd > result.startIndex {
                let previous = result[result.index(before: headEnd)]
                guard " \t,.".contains(previous) else { break }
                if ",.".contains(previous) { markBefore = true }
                headEnd = result.index(before: headEnd)
            }
            if headEnd > result.startIndex {
                let last = result[result.index(before: headEnd)]
                // After a line break or a "?" "!" ";" ":" the word cannot be a spoken mark.
                if last == "\n" || "?!;:".contains(last) { continue }
            }
            if !markBefore, nounLeaders.contains(wordEnding(at: headEnd, in: result).lowercased()) { continue }

            // What is just after: one comma or full stop written by the model, and the spaces.
            var restStart = word.upperBound
            while restStart < result.endIndex, " \t".contains(result[restStart]) { restStart = result.index(after: restStart) }
            var markAfter = false
            if restStart < result.endIndex, ",.".contains(result[restStart]) {
                markAfter = true
                restStart = result.index(after: restStart)
                while restStart < result.endIndex, " \t".contains(result[restStart]) { restStart = result.index(after: restStart) }
            }
            var rest = String(result[restStart...])
            if isPeriod, !markBefore, !markAfter, periodFollowers.contains(firstWord(of: rest).lowercased()) { continue }

            let mark = isPeriod ? "." : ","
            let space = rest.isEmpty || rest.hasPrefix("\n") ? "" : " "
            if isPeriod, let first = rest.first, first.isLowercase { rest = first.uppercased() + rest.dropFirst() }
            result = String(result[..<headEnd]) + mark + space + rest
        }
        return result
    }

    /// The letters that end the text just before `index` (empty if the character there is not a letter).
    private static func wordEnding(at index: String.Index, in text: String) -> String {
        var start = index
        while start > text.startIndex {
            let previous = text[text.index(before: start)]
            guard previous.isLetter || previous == "'" || previous == "\u{2019}" else { break }
            start = text.index(before: start)
        }
        return String(text[start..<index])
    }

    private static func firstWord(of text: String) -> String {
        String(text.prefix(while: { $0.isLetter || $0 == "'" || $0 == "\u{2019}" }))
    }
}
