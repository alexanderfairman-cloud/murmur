import Foundation

/// Tidies the raw words from the speech model before they are typed:
/// drops "um" and "uh", and fixes the spacing and capital letters that leaves behind.
public struct TextCleaner {
    public init() {}

    private static let filler = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’-])(?:um+|uh+|uhm+|erm+)(?![\p{L}\p{N}'’-]),?[ \t]*"#,
        options: [.caseInsensitive]
    )

    public func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = removeFillers(from: text)
        return Self.tidy(text)
    }

    public func trimmed(_ raw: String) -> String {
        Self.tidy(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func removeFillers(from input: String) -> String {
        var text = input
        let matches = Self.filler.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Walk backwards so earlier offsets stay valid while we edit.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: text) else { continue }
            let before = text[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let startsSentence = before.isEmpty || ".!?".contains(before.last!)
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            text.replaceSubrange(range, with: "")
            if startsSentence { text = Self.capitalizingLetter(atOrAfter: offset, in: text) }
        }
        return text
    }

    private static func capitalizingLetter(atOrAfter offset: Int, in text: String) -> String {
        var chars = Array(text)
        var i = offset
        while i < chars.count, !chars[i].isLetter {
            guard chars[i].isWhitespace || "\"'“‘(".contains(chars[i]) else { return text }
            i += 1
        }
        guard i < chars.count else { return text }
        chars[i] = Character(chars[i].uppercased())
        return String(chars)
    }

    private static func tidy(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: #"[ \t]+([,.!?;:])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #",+\s*([.!?])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
