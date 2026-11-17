import Foundation

/// Turns a spoken series into a list: "Number one, we need an icon. Number two, the colours are off." becomes
///
///     1. We need an icon.
///     2. The colours are off.
///
/// A series is recognised only by what was said, never by how the sentences look, because plain talk and a list read the same
/// without a marker. The markers are "number one", "first" or "the second thing is" (written as a numbered list), and
/// "bullet point" or "next bullet" (written with dashes). A marker counts only at the start of a sentence, only when a comma, colon
/// or full stop follows it (so "number one answer is yes" is a reply, not a list), and only as part of a series: at least two
/// markers in a row, numbered from one with none skipped. A marker that starts with "and" may also follow a comma
/// ("..., and the third thing is to chat").
///
/// In 1,668 of one speaker's real dictations only 3 contained a numbered series and none contained a list with no spoken marker,
/// so this is meant to be rare and certain. A list item runs to the next marker; the last one runs to the next paragraph break.
public enum BulletLists {
    private enum Kind: Equatable {
        case number(Int)
        case bullet
    }

    private struct Marker {
        let kind: Kind
        let range: Range<String.Index>
    }

    private static let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "first": 1, "firstly": 1, "second": 2, "secondly": 2, "third": 3, "thirdly": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8,
    ]

    // Groups: 1 = "first" / "second thing is" word, 2 = "number N", 3 = a bare "One,", 4 = a bullet word.
    private static let marker = try! NSRegularExpression(
        pattern: #"""
        (?:^|(?<=[.?!:]\ )|(?<=[,;]\ )(?=and\ ))
        (?:
            (?:and\ |also\ )?(?:the\ )?(first|second|third|fourth|fifth|sixth|seventh|eighth|firstly|secondly|thirdly)
                (?:\ (?:thing|point|item|option|reason|step|idea|question|one)\ is\b,?|[,:])
          | number\ (one|two|three|four|five|six|seven|eight|nine|ten|\d{1,2})[,:.]
          | (one|two|three|four|five|six)[,:]
          | ((?:next\ |new\ )?bullet(?:\ point)?)[,:.]
        )
        """#,
        options: [.caseInsensitive, .anchorsMatchLines, .allowCommentsAndWhitespace])

    public static func format(_ text: String) -> String {
        let markers = findMarkers(in: text)
        guard let run = firstSeries(of: markers) else { return text }

        // What is said before the first marker stays as it was, on its own line (or its own paragraph).
        let first = markers[run.lowerBound]
        let before = String(text[..<first.range.lowerBound])
        let lead = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let gap = before.suffix(while: { $0.isWhitespace })
        var result = lead.isEmpty ? "" : lead + (gap.contains("\n\n") ? "\n\n" : "\n")

        var tailStart = text.endIndex
        var lines: [String] = []
        for index in run {
            let itemStart = markers[index].range.upperBound
            var itemEnd: String.Index
            if index + 1 < run.upperBound {
                itemEnd = markers[index + 1].range.lowerBound
            } else {
                itemEnd = text.range(of: "\n\n", range: itemStart..<text.endIndex)?.lowerBound ?? text.endIndex
                tailStart = itemEnd
            }
            var item = text[itemStart..<itemEnd]
                .replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // "..., and the third thing is" ends the item before it with a comma, which a list line does not keep.
            if let last = item.last, ",;".contains(last) { item = String(item.dropLast()) + "." }
            // A marker with nothing after it ("Number two." and then silence) means this was not a finished series.
            guard item.contains(where: { $0.isLetter || $0.isNumber }) else { return text }
            let prefix = markers[index].kind == .bullet ? "- " : "\(lines.count + 1). "
            lines.append(prefix + capitalizingFirstLetter(item))
        }
        result += lines.joined(separator: "\n")

        let tail = text[tailStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? result : result + "\n\n" + format(tail)
    }

    private static func findMarkers(in text: String) -> [Marker] {
        marker.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            if match.range(at: 4).location != NSNotFound { return Marker(kind: .bullet, range: range) }
            for group in 1...3 {
                guard let word = Range(match.range(at: group), in: text) else { continue }
                let spoken = text[word].lowercased()
                guard let number = numberWords[spoken] ?? Int(spoken) else { return nil }
                return Marker(kind: .number(number), range: range)
            }
            return nil
        }
    }

    /// The first stretch of at least two markers in a row that count up from one (or are all bullets). Returns indexes into `markers`.
    private static func firstSeries(of markers: [Marker]) -> Range<Int>? {
        for start in markers.indices where markers[start].kind == .number(1) || markers[start].kind == .bullet {
            var end = start + 1
            while end < markers.count, continues(markers[end].kind, after: markers[end - 1].kind) { end += 1 }
            if end - start >= 2 { return start..<end }
        }
        return nil
    }

    private static func continues(_ next: Kind, after previous: Kind) -> Bool {
        switch (previous, next) {
        case (.bullet, .bullet): return true
        case (.number(let a), .number(let b)): return b == a + 1
        default: return false
        }
    }

    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first, first.isLowercase else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

private extension String {
    /// The run of characters at the very end of the string that satisfy `predicate`.
    func suffix(while predicate: (Character) -> Bool) -> Substring {
        var start = endIndex
        while start > startIndex, predicate(self[index(before: start)]) { start = index(before: start) }
        return self[start...]
    }
}
