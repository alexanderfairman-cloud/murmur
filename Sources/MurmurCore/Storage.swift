import Foundation

/// Which key you hold to dictate. Fn is the default, same as Wispr Flow.
public enum HotkeyChoice: String, Codable, CaseIterable {
    case fn, rightOption, rightCommand, rightControl
}

public struct Settings: Codable, Equatable {
    public var hotkey: HotkeyChoice = .fn
    public var sounds: Bool = true
    public var trailingSpace: Bool = true
    public var removeFillers: Bool = true
    /// Turn long pauses into full stops and new paragraphs. See `PauseRules`.
    public var pauseBreaks: Bool = true
    /// Use the Mac's own microphone when the chosen one is a Bluetooth headset, whose microphone can deliver no sound.
    public var preferBuiltInMicrophone: Bool = true
    public var sentencePause: Double = PauseRules().sentencePause
    public var paragraphPause: Double = PauseRules().paragraphPause

    public var pauseRules: PauseRules {
        PauseRules(enabled: pauseBreaks, sentencePause: sentencePause, paragraphPause: paragraphPause)
    }

    public init() {}

    // Missing keys fall back to defaults, so adding a setting later never breaks an old file.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        hotkey = try c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey) ?? d.hotkey
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        trailingSpace = try c.decodeIfPresent(Bool.self, forKey: .trailingSpace) ?? d.trailingSpace
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? d.removeFillers
        pauseBreaks = try c.decodeIfPresent(Bool.self, forKey: .pauseBreaks) ?? d.pauseBreaks
        preferBuiltInMicrophone = try c.decodeIfPresent(Bool.self, forKey: .preferBuiltInMicrophone) ?? d.preferBuiltInMicrophone
        sentencePause = try c.decodeIfPresent(Double.self, forKey: .sentencePause) ?? d.sentencePause
        paragraphPause = try c.decodeIfPresent(Double.self, forKey: .paragraphPause) ?? d.paragraphPause
    }
}

/// Where Murmur keeps its files: `~/Library/Application Support/Murmur/`. Nothing here ever leaves the Mac.
public struct AppFiles {
    public let directory: URL
    public var settingsURL: URL { directory.appendingPathComponent("settings.json") }
    public var dictionaryURL: URL { directory.appendingPathComponent("dictionary.json") }
    public var historyURL: URL { directory.appendingPathComponent("history.jsonl") }

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    public func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else {
            let defaults = Settings()
            saveSettings(defaults)
            return defaults
        }
        return settings
    }

    public func saveSettings(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) { try? data.write(to: settingsURL, options: .atomic) }
    }

    // MARK: Dictionary

    private struct DictionaryFile: Codable { var entries: [DictionaryEntry] }

    /// Reads the dictionary file. The first time, it writes a short starter list you can edit.
    /// Throws if the file exists but cannot be read (usually a missing comma or quote after hand editing).
    public func loadDictionary() throws -> [DictionaryEntry] {
        guard FileManager.default.fileExists(atPath: dictionaryURL.path) else {
            saveDictionary(Self.starterDictionary)
            return Self.starterDictionary
        }
        let data = try Data(contentsOf: dictionaryURL)
        return try JSONDecoder().decode(DictionaryFile.self, from: data).entries
    }

    public func saveDictionary(_ entries: [DictionaryEntry]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(DictionaryFile(entries: entries)) {
            try? data.write(to: dictionaryURL, options: .atomic)
        }
    }

    public var dictionaryModified: Date? {
        (try? FileManager.default.attributesOfItem(atPath: dictionaryURL.path))?[.modificationDate] as? Date
    }

    public static let starterDictionary: [DictionaryEntry] = [
        DictionaryEntry(word: "Claude Code", heardAs: ["clawed code", "claw code", "cloud code", "clod code"]),
        DictionaryEntry(word: "Claude", heardAs: ["clawed", "cloud ai"]),
        DictionaryEntry(word: "Anthropic"),
        DictionaryEntry(word: "Supabase", heardAs: ["super base", "super bass", "supa base"]),
        DictionaryEntry(word: "Vercel", heardAs: ["versel", "ver sell"]),
        DictionaryEntry(word: "Playwright", heardAs: ["play right"]),
        DictionaryEntry(word: "Next.js", heardAs: ["next js", "nextjs"]),
        DictionaryEntry(word: "Freya", heardAs: ["fraya", "freyja"]),
        DictionaryEntry(word: "Higgsfield", heardAs: ["higgs field"]),
        DictionaryEntry(word: "Documenso"),
        DictionaryEntry(word: "Apify"),
    ]
}

public struct HistoryItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var date: Date
    /// What was typed.
    public var text: String
    /// What the speech model said before cleanup and dictionary.
    public var rawText: String
    public var audioSeconds: Double
    public var transcribeMs: Int
    public var app: String?
    /// The app's bundle identifier, used to show its real icon. Missing on older entries.
    public var appID: String?
    public var corrections: [Correction]

    public init(
        id: UUID = UUID(), date: Date = Date(), text: String, rawText: String,
        audioSeconds: Double, transcribeMs: Int, app: String?, appID: String? = nil, corrections: [Correction]
    ) {
        self.appID = appID
        self.id = id
        self.date = date
        self.text = text
        self.rawText = rawText
        self.audioSeconds = audioSeconds
        self.transcribeMs = transcribeMs
        self.app = app
        self.corrections = corrections
    }
}

/// Every dictation, one JSON line per entry, newest last on disk. Used from the main thread only.
public final class HistoryStore {
    private let url: URL
    /// Newest first.
    public private(set) var items: [HistoryItem] = []

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(url: URL) {
        self.url = url
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // A damaged line is skipped, never fatal.
        items = text.split(separator: "\n").compactMap { line in
            try? Self.decoder.decode(HistoryItem.self, from: Data(line.utf8))
        }.reversed()
        if items.count > 2000 { items = Array(items.prefix(2000)) }
    }

    public func recent(_ count: Int) -> [HistoryItem] { Array(items.prefix(count)) }

    /// Replaces a dictation (matched by its id), for example after a word in it was fixed.
    public func replace(_ item: HistoryItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i] = item
        rewrite()
    }

    /// Deletes dictations for good, rewriting the file without them.
    public func remove(ids: Set<UUID>) {
        guard items.contains(where: { ids.contains($0.id) }) else { return }
        items.removeAll { ids.contains($0.id) }
        rewrite()
    }

    private func rewrite() {
        var data = Data()
        for item in items.reversed() { // the file is oldest first
            guard let line = try? Self.encoder.encode(item) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        try? data.write(to: url, options: .atomic)
    }

    public func append(_ item: HistoryItem) {
        items.insert(item, at: 0)
        guard var line = try? Self.encoder.encode(item) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}
