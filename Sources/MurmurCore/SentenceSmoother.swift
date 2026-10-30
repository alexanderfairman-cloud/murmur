import Foundation

/// The speech model ends a sentence when it hears a hesitation, so a thinking pause before "and" or "but" comes out as
/// "you have. And Lee shared..." when "you have, and Lee shared..." was meant. A sentence that starts with one of
/// these joining words is nearly always the second half of the one before it, so the full stop becomes a comma.
/// Only full stops on the same line are touched: a blank line is a real pause and stays, and so do "?" and "!".
public enum SentenceSmoother {
    // A word character before the stop, and not "etc" (its stop belongs to the word).
    private static let pattern = try! NSRegularExpression(pattern: #"(?<=\w)(?<!etc)\. (And|But|Or) "#)

    public static func smooth(_ text: String) -> String {
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result), let word = Range(match.range(at: 1), in: result) else { continue }
            result.replaceSubrange(whole, with: ", " + result[word].lowercased() + " ")
        }
        return result
    }
}
