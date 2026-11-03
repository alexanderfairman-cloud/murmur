import Foundation

/// The speech model ends a sentence when it hears a hesitation, so a thinking pause before "and" or "but" comes out as
/// "you have. And Lee shared..." when "you have, and Lee shared..." was meant. A sentence that starts with one of
/// these joining words is nearly always the second half of the one before it, so the full stop becomes a comma.
/// "Because" and "Which" work the same way ("Which one do you want?" is a question and stays).
/// "So" is left alone on purpose: in 7 of 8 real cases in one speaker's saved dictations "So I" or "So we" started a new sentence.
/// Only full stops on the same line are touched: a blank line is a real pause and stays, and so do "?" and "!".
public enum SentenceSmoother {
    // A word character before the stop, and not "etc" (its stop belongs to the word).
    private static let pattern = try! NSRegularExpression(
        pattern: #"(?<=\w)(?<!etc)\. (?:(And|But|Or|Because) |(Which) (?![^.!?]*\?))"#)

    public static func smooth(_ text: String) -> String {
        var result = text
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(match.range, in: result),
                  let word = (1...2).lazy.compactMap({ Range(match.range(at: $0), in: result) }).first
            else { continue }
            result.replaceSubrange(whole, with: ", " + result[word].lowercased() + " ")
        }
        return result
    }
}
