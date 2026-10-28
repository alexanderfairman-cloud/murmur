import Foundation

/// The dictionary as the Words screen edits it. Every change returns quickly and the caller saves the result.
public struct WordList: Equatable {
    public private(set) var entries: [DictionaryEntry]

    public init(entries: [DictionaryEntry] = []) {
        self.entries = entries
    }

    public func contains(_ word: String) -> Bool {
        index(of: word) != nil
    }

    private func index(of word: String) -> Int? {
        entries.firstIndex { $0.word.caseInsensitiveCompare(word) == .orderedSame }
    }

    /// Adds a word at the top of the list. False when it is empty or already there.
    @discardableResult
    public mutating func add(_ raw: String) -> Bool {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !contains(word) else { return false }
        entries.insert(DictionaryEntry(word: word), at: 0)
        return true
    }

    public mutating func remove(_ words: Set<String>) {
        entries.removeAll { words.contains($0.word) }
    }

    /// Adds a wrong spelling the model tends to produce for `word`. False when it is empty, a repeat, or the word itself.
    @discardableResult
    public mutating func addHeardAs(_ raw: String, to word: String) -> Bool {
        let heard = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !heard.isEmpty, let i = index(of: word),
              heard != entries[i].word.lowercased(), !entries[i].heardAs.contains(heard)
        else { return false }
        entries[i].heardAs.append(heard)
        return true
    }

    public mutating func removeHeardAs(_ heard: String, from word: String) {
        guard let i = index(of: word) else { return }
        entries[i].heardAs.removeAll { $0 == heard }
    }

    /// Words whose spelling, or any wrong spelling, contains `query`. An empty query returns everything.
    public func matching(_ query: String) -> [DictionaryEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            entry.word.lowercased().contains(q) || entry.heardAs.contains { $0.contains(q) }
        }
    }

    /// How many dictations each word has fixed, by word.
    public func usage(in history: [HistoryItem]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.word] = history.reduce(0) { total, item in
                total + (item.corrections.contains { $0.written == entry.word } ? 1 : 0)
            }
        }
        return counts
    }
}
