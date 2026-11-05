import Foundation

/// Decides whether a stretch of dictated text could be the end of a sentence, from its grammar rather than from how long
/// the speaker paused. A pause of two seconds is as likely to be thinking as finishing, but "an event is simply" or
/// "because to me" cannot be finished however long the quiet lasts.
///
/// The word lists below were picked from 14,686 real dictations (33,460 sentences, punctuated by a careful editor):
/// each word in "cannotEnd" ended a sentence in under about 3 percent of its uses (most under 1), and each word in
/// "carriesOn" opened a sentence in under 0.1 percent of the sentences but followed a mid-sentence cut about 25 times as often.
/// Measured on 26,390 of those sentences, `isUnfinished` wrongly calls 2.8 percent of real sentence endings unfinished and
/// catches 50 percent of the cuts made at random places inside a sentence; the strict tier (`endsOnCertainWord`) wrongly calls
/// 0.6 percent and catches 36 percent. The rest of the cuts stop on a noun or an adjective, which no check on the words
/// alone can tell from a finished sentence. That is why a pause of two seconds backs up the loose check, and the strict one
/// is the only one used on text with no pause behind it.
public enum SentenceCompleteness {
    /// A last word that cannot finish a sentence: it opens or links a phrase and something must follow.
    private static let cannotEnd: Set<String> = [
        // articles, possessives and quantifiers
        "a", "an", "the", "my", "your", "our", "their", "his", "its", "some", "any", "every", "another", "such", "few",
        "many", "most", "several", "various", "multiple",
        // prepositions and links
        "of", "to", "for", "with", "from", "at", "into", "between", "across", "via", "per", "without", "versus",
        "regarding", "including", "given", "until", "than", "as", "like", "based",
        // joining and asking words
        "and", "or", "but", "because", "if", "when", "while", "although", "whereas", "unless", "whether", "which",
        "who", "whose", "where", "what", "how", "then", "also", "therefore",
        // helping verbs
        "be", "been", "is", "are", "was", "were", "has", "had", "can", "could", "should", "will", "would", "might",
        "may", "must", "shall", "going", "gonna", "let", "let's", "don't", "doesn't", "isn't", "can't", "won't", "haven't",
        // a subject with no verb yet
        "i", "we", "they", "he", "she", "i'm", "i'll", "i'd", "i've", "we're", "we'll", "we'd", "we've", "they're",
        "they'll", "they've", "you're", "you'll", "you'd", "you've", "he's", "she's", "it's", "it'll", "that's",
        "there's", "here's", "what's", "who's",
        // adverbs that sit in front of what they describe
        "just", "really", "actually", "very", "even", "probably", "definitely", "basically", "simply", "obviously",
        "absolutely", "quite", "pretty", "rather", "maybe", "almost", "never", "finally", "currently", "essentially",
        "literally", "merely", "mainly", "mostly", "typically", "usually", "generally", "particularly", "especially",
        "primarily",
        // verbs that need something after them
        "make", "makes", "get", "getting", "got", "give", "gives", "create", "creating", "add", "adding", "generate",
        "show", "shows", "send", "sending", "provide", "include", "includes", "allow", "find", "ask", "tell", "put",
        "keep", "try", "trying", "taking", "remove", "replace", "explain", "integrate", "identify", "analyze",
        "evaluate", "determine", "consider", "propose", "write", "helping", "having", "looking", "looks", "seems",
        "seem", "feels", "sounds", "talking", "noticing", "starting", "setting", "moving", "think", "delineate",
        "differentiate", "distinguish", "describe", "define", "establish", "ensure", "enable",
        // adjectives that sit in front of a noun
        "new", "current", "specific", "single", "entire", "full", "existing", "unique", "major", "initial", "primary",
        "personal", "certain", "exact", "actual", "able", "third", "called",
    ]

    /// The words in `cannotEnd` that now and then do end a sentence ("that is what it is", "I will do both"). Fine to act on when a
    /// long pause backs them up; too risky to act on alone (see `isCertainlyUnfinished`).
    private static let sometimesEnds: Set<String> = [
        "primarily", "another", "had", "especially", "was", "than", "currently", "are", "typically", "must", "is", "replace",
        "evaluate", "never", "like", "without", "therefore", "determine", "give", "generally", "going", "moving", "across",
        "tell", "keep", "shows", "try", "make", "send", "at", "isn't", "then", "show", "most", "with", "multiple", "got", "add",
        "from", "may", "given", "many", "ask", "be", "definitely", "actually", "called", "probably", "remove", "having",
        "provide", "into", "for", "maybe", "new", "starting", "can't", "creating", "while", "has", "can", "were",
        "delineate", "differentiate", "distinguish", "describe", "define", "establish", "ensure", "enable",
    ]

    /// Words that start a clause which needs its own subject and verb ("because it works", "if you ask").
    private static let clauseOpeners: Set<String> = [
        "because", "if", "when", "whenever", "whereas", "although", "though", "while", "since", "unless", "until", "whether",
    ]

    /// Words that start a condition, which needs a second half.
    private static let conditionOpeners: Set<String> = [
        "if", "when", "once", "because", "although", "though", "while", "unless", "until", "whenever", "whereas",
    ]

    /// Words that cannot be a clause's verb: after "because" they leave it with no predicate ("because to me", "if you").
    private static let noPredicate: Set<String> = [
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her", "us", "them", "this", "that", "these", "those",
        "there", "here", "the", "a", "an", "my", "your", "his", "its", "our", "their", "some", "any", "every", "each",
        "all", "no", "another", "to", "of", "for", "with", "from", "at", "in", "on", "by", "into", "about", "over",
        "under", "through", "also", "just", "really",
    ]

    /// Words that almost never open a sentence but often open the rest of one: a piece that starts with one carries on from the piece before.
    private static let carriesOn: Set<String> = ["of", "be", "into", "about", "up", "them", "out", "me", "through", "than"]

    private static let certainlyCannotEnd = cannotEnd.subtracting(sometimesEnds)

    /// True when the text cannot end a sentence where it stops: the speech model left a comma, semicolon or colon,
    /// the last word cannot finish one, a clause has no verb, or a condition has no second half.
    /// Use it where a long pause backs it up (the speaker stopped talking), because it also calls 2.8 percent of real endings unfinished.
    public static func isUnfinished(_ text: String) -> Bool {
        unfinished(text, lastWords: cannotEnd)
    }

    /// True when the last word is one that all but never ends a sentence (under 0.4 percent of its uses). Even so, a real
    /// sentence sometimes ends on one ("the services we are hooked up to."), so act on it only with other evidence.
    public static func endsOnCertainWord(_ text: String) -> Bool {
        guard let last = lastSentence(of: text)?.words.last else { return false }
        return certainlyCannotEnd.contains(last)
    }

    /// True when the last sentence is a clause with no verb ("because to me") or a condition with no second half
    /// ("If you have any questions"). Nothing can follow such a sentence but its own other half.
    public static func isDanglingClause(_ text: String) -> Bool {
        guard let last = lastSentence(of: text) else { return false }
        return clauseHasNoPredicate(last.words) || conditionHasNoResult(last.sentence, last.words)
    }

    private static func unfinished(_ text: String, lastWords: Set<String>) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.last, ",;:".contains(end) { return true }
        guard let last = lastSentence(of: text) else { return false }
        return last.words.last.map { lastWords.contains($0) } == true || isDanglingClause(text)
    }

    /// The last sentence of the text and its words; nil for empty text and for one that ends in "?" or "!", which is finished whatever its last word.
    private static func lastSentence(of text: String) -> (sentence: String, words: [String])? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let end = trimmed.last, !"?!".contains(end) else { return nil }
        // A sentence ends at a mark followed by a space or the end of the text, so "L.A." and "3.5" stay whole.
        let marked = trimmed.replacingOccurrences(of: #"[.?!]+(\s+|$)"#, with: "\u{1}", options: .regularExpression)
        let sentence = marked.split(separator: "\u{1}").last.map(String.init) ?? trimmed
        let found = words(in: sentence)
        return found.isEmpty ? nil : (sentence, found)
    }

    /// True when a separately written piece cannot open a sentence ("of the plan", "into the system"): it carries on from the piece before.
    public static func carriesOnFromBefore(_ text: String) -> Bool {
        let found = words(in: text)
        guard let first = found.first, carriesOn.contains(first) else { return false }
        return !(first == "of" && found.dropFirst().first == "course")
    }

    /// True when two pieces, split at a long pause, are really one sentence.
    public static func joins(_ left: String, _ right: String) -> Bool {
        isUnfinished(left) || carriesOnFromBefore(right)
    }

    /// "because to me": a clause opener followed only by words that cannot be a verb.
    private static func clauseHasNoPredicate(_ found: [String]) -> Bool {
        guard let at = found.lastIndex(where: { clauseOpeners.contains($0) }) else { return false }
        let after = found[(at + 1)...]
        guard !after.isEmpty, after.count <= 4, after.allSatisfy({ noPredicate.contains($0) }) else { return false }
        // "because of this" is a finished phrase: here "of" is a preposition, not the start of a clause.
        return !(found[at] == "because" && after.first == "of")
    }

    /// "If you have any questions": starts with a condition word, is short and has no comma where the second half would begin.
    private static func conditionHasNoResult(_ sentence: String, _ found: [String]) -> Bool {
        (3...10).contains(found.count) && !sentence.contains(",") && conditionOpeners.contains(found[0])
    }

    /// True when the last sentence of the text is a condition whose second half has not begun, so it is joined with a comma.
    public static func endsOnOpenCondition(_ text: String) -> Bool {
        guard let last = lastSentence(of: text) else { return false }
        return !last.sentence.contains(",") && conditionOpeners.contains(last.words[0])
    }

    /// The words of the text, lowercased, with the marks around each one dropped. Numbers and "L.A" count as words.
    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased().replacingOccurrences(of: "\u{2019}", with: "'") }
            .filter { !$0.isEmpty }
    }
}
