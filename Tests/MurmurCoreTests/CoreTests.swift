import Foundation
import Testing
@testable import MurmurCore

@Suite("Text cleanup")
struct TextCleanerTests {
    let cleaner = TextCleaner()

    @Test func dropsFillerAtStartAndCapitalizesNextWord() {
        #expect(cleaner.clean("Um, I think we should go.") == "I think we should go.")
        #expect(cleaner.clean("Okay. Um, so that works.") == "Okay. So that works.")
    }

    @Test func dropsFillerInMiddleKeepingCommas() {
        #expect(cleaner.clean("I think, um, we should go.") == "I think, we should go.")
        #expect(cleaner.clean("so um I think we should go") == "so I think we should go")
    }

    @Test func dropsFillerAtEnd() {
        #expect(cleaner.clean("I was going to, uh.") == "I was going to.")
        #expect(cleaner.clean("I was going to um") == "I was going to")
    }

    @Test func leavesRealWordsAlone() {
        #expect(cleaner.clean("The umbrella is in the Uhura room.") == "The umbrella is in the Uhura room.")
        #expect(cleaner.clean("uh-oh, that broke") == "uh-oh, that broke")
        #expect(cleaner.clean("") == "")
    }

    @Test func keepsParagraphBreaksAroundFillers() {
        #expect(cleaner.clean("Done.\n\nUm, next one.") == "Done.\n\nNext one.")
    }

    @Test func tidiesSpacing() {
        #expect(cleaner.clean("  hello  world , ok .  ") == "hello world, ok.")
    }
}

@Suite("Dictionary")
struct DictionaryCorrectorTests {
    static let entries = AppFiles.starterDictionary + [DictionaryEntry(word: "Resend")]
    func corrector(known: Set<String> = []) -> DictionaryCorrector {
        DictionaryCorrector(entries: Self.entries, isKnownWord: { known.contains($0) })
    }

    @Test func usesHeardAsSpellings() {
        let r = corrector().apply(to: "I use clawed code every day.")
        #expect(r.text == "I use Claude Code every day.")
        #expect(r.corrections == [Correction(heard: "clawed code", written: "Claude Code")])
    }

    @Test func keepsPunctuationAndSurroundingText() {
        #expect(corrector().apply(to: "Try clawed code. Then stop!").text == "Try Claude Code. Then stop!")
    }

    @Test func joinsSplitWords() {
        #expect(corrector().apply(to: "We host on super base now").text == "We host on Supabase now")
        #expect(corrector().apply(to: "built with next js").text == "built with Next.js")
    }

    @Test func fixesCapitalsOfDictionaryWords() {
        #expect(corrector().apply(to: "supabase and vercel").text == "Supabase and Vercel")
    }

    @Test func nearMissOnlyWhenNotARealWord() {
        // "Versel" is one letter off Vercel and is not a word, so it is fixed. "Versal" is two off, so it is left alone.
        #expect(corrector().apply(to: "deploy to Versel").text == "deploy to Vercel")
        #expect(corrector().apply(to: "deploy to Versal").text == "deploy to Versal")
        // "resent" is one letter off Resend but is a real word, so it stays.
        #expect(corrector(known: ["resent"]).apply(to: "I resent that").text == "I resent that")
    }

    @Test func lowercaseWordsNeverForceACapitalOrTakeOneAway() {
        let c = DictionaryCorrector(entries: [
            DictionaryEntry(word: "stripe", heardAs: ["strype"]),
            DictionaryEntry(word: "andrew"),
        ])
        // Already right apart from capitals: left exactly as the model wrote it.
        #expect(c.apply(to: "Stripe is down").text == "Stripe is down")
        #expect(c.apply(to: "we use stripe").text == "we use stripe")
        #expect(c.apply(to: "I asked Andrew about it").text == "I asked Andrew about it")
        #expect(c.apply(to: "Stripe is down").corrections.isEmpty)
        // A wrong spelling becomes the lowercase word, with a capital only at the start of a sentence.
        #expect(c.apply(to: "we use strype").text == "we use stripe")
        #expect(c.apply(to: "Strype is down").text == "Stripe is down")
        #expect(c.apply(to: "It works. strype is up").text == "It works. Stripe is up")
        #expect(c.apply(to: "First line.\nstrype again").text == "First line.\nStripe again")
        #expect(c.apply(to: "\"strype is down,\" he said").text == "\"Stripe is down,\" he said")
    }

    @Test func wordsWithACapitalStillForceIt() {
        let c = DictionaryCorrector(entries: [DictionaryEntry(word: "Enneagram")])
        #expect(c.apply(to: "my enneagram type").text == "my Enneagram type")
    }

    @Test func noChangeMeansNoCorrections() {
        let r = corrector().apply(to: "Claude Code is fine")
        #expect(r.text == "Claude Code is fine")
        #expect(r.corrections.isEmpty)
    }

    @Test func emptyDictionaryIsANoOp() {
        #expect(DictionaryCorrector(entries: []).apply(to: "anything at all").text == "anything at all")
    }
}

@Suite("Pause breaks")
struct PauseBreakTests {
    private let rate = SilenceSplitter.sampleRate

    /// A steady tone, standing in for speech.
    private func speech(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { 0.3 * sin(2 * Float.pi * 220 * Float($0) / Float(rate)) }
    }

    private func quiet(_ seconds: Double, noise: Float = 0) -> [Float] {
        var seed: UInt32 = 12345
        return (0..<Int(seconds * Double(rate))).map { _ in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return noise * (Float(seed >> 8) / Float(1 << 24) * 2 - 1)
        }
    }

    @Test func cutsAtALongSilenceAndMeasuresIt() {
        let parts = SilenceSplitter().split(speech(1.0) + quiet(1.2) + speech(1.0))
        #expect(parts.count == 2)
        #expect(parts[0].silenceBefore == 0)
        #expect(abs(parts[1].silenceBefore - 1.2) < 0.05)
        #expect(parts[0].range.upperBound <= parts[1].range.lowerBound + 1)
    }

    @Test func aShortGapIsNotACut() {
        #expect(SilenceSplitter().split(speech(1.0) + quiet(0.4) + speech(1.0)).count == 1)
    }

    @Test func dropsQuietAtTheStartAndEnd() {
        let parts = SilenceSplitter().split(quiet(2) + speech(1.0) + quiet(2))
        #expect(parts.count == 1)
        let seconds = Double(parts[0].range.count) / Double(rate)
        #expect(abs(seconds - 1.3) < 0.05)
    }

    @Test func noSpeechMeansNoPieces() {
        #expect(SilenceSplitter().split(quiet(3)).isEmpty)
        #expect(SilenceSplitter().split([]).isEmpty)
    }

    @Test func backgroundNoiseStillCountsAsQuiet() {
        let parts = SilenceSplitter().split(speech(1.0) + quiet(1.5, noise: 0.004) + speech(1.0))
        #expect(parts.count == 2)
    }

    @Test func theLimitIsAdjustable() {
        let audio = speech(1.0) + quiet(1.0) + speech(1.0)
        #expect(SilenceSplitter(minimumPause: 1.5).split(audio).count == 1)
        #expect(SilenceSplitter(minimumPause: 0.5).split(audio).count == 2)
    }

    @Test func joinsIntoSentencesAndParagraphs() {
        let text = SentenceJoiner.join(
            [("I use it every day", 0), ("then I ship it", 1.2), ("please rebuild", 2.6)], paragraphPause: 1.8)
        #expect(text == "I use it every day. Then I ship it.\n\nPlease rebuild")
    }

    @Test func aCommaAtTheEndOfAPieceBecomesAFullStop() {
        #expect(SentenceJoiner.join([("Hello there,", 0), ("how are you?", 1.0)], paragraphPause: 1.8)
            == "Hello there. How are you?")
    }

    @Test func emptyPiecesAreSkipped() {
        #expect(SentenceJoiner.join([("One.", 0), ("  ", 1.0), ("Two.", 1.0)], paragraphPause: 1.8) == "One. Two.")
    }

    @Test func spotsASentenceThatWasNotFinished() {
        #expect(SentenceJoiner.endsMidSentence("I would like to"))
        #expect(SentenceJoiner.endsMidSentence("We bought the."))
        #expect(SentenceJoiner.endsMidSentence("I'm going to the"))
        #expect(!SentenceJoiner.endsMidSentence("That is it."))
        #expect(!SentenceJoiner.endsMidSentence("Ready"))
        #expect(!SentenceJoiner.endsMidSentence(""))
    }
}

@Suite("Words and history lists")
struct WindowLogicTests {
    @Test func addsNewWordsAtTheTopAndRefusesRepeats() {
        var list = WordList(entries: [DictionaryEntry(word: "Vercel")])
        let added = list.add("  Supabase ")
        #expect(added)
        #expect(list.entries.map(\.word) == ["Supabase", "Vercel"])
        let repeated = list.add("supabase")
        let blank = list.add("   ")
        #expect(!repeated && !blank)
    }

    @Test func editsWrongSpellings() {
        var list = WordList(entries: [DictionaryEntry(word: "Supabase")])
        let added = list.addHeardAs(" Super Base ", to: "Supabase")
        #expect(added)
        #expect(list.entries[0].heardAs == ["super base"])
        let repeated = list.addHeardAs("super base", to: "Supabase")
        let itself = list.addHeardAs("supabase", to: "Supabase")
        let blank = list.addHeardAs("", to: "Supabase")
        #expect(!repeated && !itself && !blank)
        list.removeHeardAs("super base", from: "Supabase")
        #expect(list.entries[0].heardAs.isEmpty)
    }

    @Test func removesSeveralWordsAtOnce() {
        var list = WordList(entries: ["A", "B", "C"].map { DictionaryEntry(word: $0) })
        list.remove(["A", "C"])
        #expect(list.entries.map(\.word) == ["B"])
    }

    @Test func searchLooksAtWordsAndWrongSpellings() {
        let list = WordList(entries: [
            DictionaryEntry(word: "Claude Code", heardAs: ["clawed code"]),
            DictionaryEntry(word: "Vercel"),
        ])
        #expect(list.matching("claw").map(\.word) == ["Claude Code"])
        #expect(list.matching("VER").map(\.word) == ["Vercel"])
        #expect(list.matching("").count == 2)
        #expect(list.matching("zzz").isEmpty)
    }

    @Test func countsHowOftenAWordWasFixed() {
        let list = WordList(entries: [DictionaryEntry(word: "Vercel"), DictionaryEntry(word: "Apify")])
        func item(_ fixes: [Correction]) -> HistoryItem {
            HistoryItem(text: "t", rawText: "t", audioSeconds: 1, transcribeMs: 1, app: nil, corrections: fixes)
        }
        let history = [
            item([Correction(heard: "versel", written: "Vercel")]),
            item([Correction(heard: "versel", written: "Vercel"), Correction(heard: "versel", written: "Vercel")]),
            item([]),
        ]
        #expect(list.usage(in: history) == ["Vercel": 2, "Apify": 0])
    }

    @Test func groupsDictationsIntoDays() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = utc.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 15))!
        func at(_ day: Int, _ hour: Int) -> HistoryItem {
            HistoryItem(
                date: utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!,
                text: "\(day)-\(hour)", rawText: "", audioSeconds: 1, transcribeMs: 1, app: nil, corrections: [])
        }
        let days = HistoryGrouping.days(
            [at(28, 12), at(28, 9), at(27, 17), at(25, 8)], now: now, calendar: utc, locale: Locale(identifier: "en_US"))
        #expect(days.map(\.title).prefix(2) == ["Today", "Yesterday"])
        #expect(days[2].title.contains("October 25"))
        #expect(days.map { $0.items.count } == [2, 1, 1])
        #expect(days[0].items.map(\.text) == ["28-12", "28-9"])
    }

    @Test func searchFindsTextHeardWordsAndApps() {
        let item = HistoryItem(
            text: "Ship it on Friday", rawText: "ship it on friday super base", audioSeconds: 1, transcribeMs: 1,
            app: "Cursor", corrections: [])
        #expect(item.matches("friday") && item.matches("SUPER BASE") && item.matches("cursor") && item.matches(" "))
        #expect(!item.matches("tuesday"))
    }

    @Test func deletingADictationRewritesTheFile() throws {
        let files = AppFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("murmur-test-\(UUID().uuidString)"))
        let store = HistoryStore(url: files.historyURL)
        let keep = HistoryItem(text: "keep", rawText: "keep", audioSeconds: 1, transcribeMs: 1, app: nil, appID: "com.apple.Notes", corrections: [])
        let drop = HistoryItem(text: "drop", rawText: "drop", audioSeconds: 1, transcribeMs: 1, app: nil, corrections: [])
        store.append(keep)
        store.append(drop)
        store.remove(ids: [drop.id])
        let reloaded = HistoryStore(url: files.historyURL)
        #expect(reloaded.items.map(\.text) == ["keep"])
        #expect(reloaded.items[0].appID == "com.apple.Notes")
    }
}

@Suite("Fix a word")
struct FixAWordTests {
    @Test func splitsIntoWordsAndKeepsPunctuationApart() {
        let t = FixTokens("Ask Jodi, then \"Next.js\" and don't stop.\n\nNew line here")
        #expect(t.tokens.map(\.core) == ["Ask", "Jodi", "then", "Next.js", "and", "don't", "stop", "New", "line", "here"])
        #expect(t.tokens[1].text == "Jodi,")
        #expect(t.tokens[7].lineBreaksBefore == 2 && t.tokens[8].lineBreaksBefore == 0)
    }

    @Test func heardIsTheWordsWithoutPunctuation() {
        let t = FixTokens("Tell play right, please")
        #expect(t.heard(1...2) == "play right")
        #expect(t.heard(5...6).isEmpty)
    }

    @Test func replacingKeepsThePunctuationAroundTheChosenWords() {
        let t = FixTokens("Ask her, please")
        let one = t.replacing(1...1, with: "Jara")
        #expect(one?.text == "Ask Jara, please")
        #expect(one?.range == 4..<8)
        let two = FixTokens("I use \"play right\" daily").replacing(2...3, with: "Playwright")
        #expect(two?.text == "I use \"Playwright\" daily")
        #expect(FixTokens("one two").replacing(0...5, with: "x") == nil)
    }

    @Test func choosingWordsExtendsOnlyToNeighboursUpToFour() {
        var s = FixSelection()
        s.tap(3)
        #expect(s.range == 3...3)
        s.tap(4)
        #expect(s.range == 3...4)
        s.tap(2)
        #expect(s.range == 2...4)
        #expect(s.isNeighbor(1) && s.isNeighbor(5) && !s.isNeighbor(0))
        s.tap(5)
        #expect(s.range == 2...5)
        #expect(!s.isNeighbor(6))
        s.tap(6)
        #expect(s.range == 6...6)
        s.tap(6)
        #expect(s.range == 6...6)
        s.tap(0)
        #expect(s.range == 0...0)
    }

    @Test func warnsOnlyForOrdinaryWords() {
        let real: (String) -> Bool = { ["her", "tell", "jodi"].contains($0) }
        let t = FixTokens("Ask Annabelle and Jodi about it, tell her. Tell me")
        #expect(t.looksLikeEverydayWord(7...7, isRealWord: real))      // "her"
        #expect(!t.looksLikeEverydayWord(3...3, isRealWord: real))     // "Jodi", capitalised mid-sentence: a name
        #expect(t.looksLikeEverydayWord(8...8, isRealWord: real))      // "Tell" starting a sentence
        #expect(!t.looksLikeEverydayWord(1...2, isRealWord: real))     // two words at once
        #expect(!t.looksLikeEverydayWord(1...1, isRealWord: { _ in false }))
    }

    @Test func claimingASpellingMovesItFromAnotherWord() {
        var list = WordList(entries: [
            DictionaryEntry(word: "Jyoti"),
            DictionaryEntry(word: "Jodi", heardAs: ["joddy"]),
        ])
        let claimed = list.claim("Joddy", for: "Jyoti")
        #expect(claimed)
        #expect(list.entries[0].heardAs == ["joddy"])
        #expect(list.entries[1].heardAs.isEmpty)
        let again = list.claim("joddy", for: "Jyoti")
        let itself = list.claim("jyoti", for: "Jyoti")
        #expect(!again && !itself)
    }

    @Test func suggestsCloseWordsThenWordsThatStartWithWhatIsTyped() {
        let list = WordList(entries: ["Jyoti", "Jara", "Annabel", "Henry", "Raamayan"].map { DictionaryEntry(word: $0) })
        #expect(list.suggestions(heard: "Jodi", typed: "").contains("Jyoti"))
        #expect(!list.suggestions(heard: "Jodi", typed: "").contains("Raamayan"))
        #expect(list.suggestions(heard: "Jodi", typed: "Ja") == ["Jara"])
        #expect(list.suggestions(heard: "Jodi", typed: "jara").isEmpty)
    }

    @Test func replacingAHistoryEntryRewritesTheFile() throws {
        let files = AppFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("murmur-test-\(UUID().uuidString)"))
        let store = HistoryStore(url: files.historyURL)
        var item = HistoryItem(text: "Ask Jodi", rawText: "Ask Jodi", audioSeconds: 1, transcribeMs: 1, app: "Notes", corrections: [])
        store.append(item)
        store.append(HistoryItem(text: "other", rawText: "other", audioSeconds: 1, transcribeMs: 1, app: nil, corrections: []))
        item.text = "Ask Jyoti"
        item.corrections = [Correction(heard: "Jodi", written: "Jyoti")]
        store.replace(item)
        let reloaded = HistoryStore(url: files.historyURL)
        #expect(reloaded.items.map(\.text) == ["other", "Ask Jyoti"])
        #expect(reloaded.items[1].corrections == [Correction(heard: "Jodi", written: "Jyoti")])
    }
}

@Suite("Storage")
struct StorageTests {
    func tempFiles() -> AppFiles {
        AppFiles(directory: FileManager.default.temporaryDirectory.appendingPathComponent("murmur-test-\(UUID().uuidString)"))
    }

    @Test func historyRoundTripsAndSurvivesADamagedLine() throws {
        let files = tempFiles()
        let store = HistoryStore(url: files.historyURL)
        store.append(HistoryItem(text: "first", rawText: "first", audioSeconds: 1, transcribeMs: 10, app: "Notes", corrections: []))
        store.append(HistoryItem(text: "second", rawText: "second", audioSeconds: 2, transcribeMs: 20, app: nil,
                                 corrections: [Correction(heard: "a", written: "b")]))
        let handle = try FileHandle(forWritingTo: files.historyURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()

        let reloaded = HistoryStore(url: files.historyURL)
        #expect(reloaded.items.map(\.text) == ["second", "first"])
        #expect(reloaded.items[0].corrections.first?.written == "b")
    }

    @Test func settingsFillInMissingKeys() throws {
        let old = Data(#"{"hotkey":"rightOption"}"#.utf8)
        let s = try JSONDecoder().decode(Settings.self, from: old)
        #expect(s.hotkey == .rightOption)
        #expect(s.sounds && s.trailingSpace && s.removeFillers && s.pauseBreaks && s.preferBuiltInMicrophone)
        #expect(s.pauseRules == PauseRules(enabled: true, sentencePause: 0.8, paragraphPause: 1.8))
    }

    @Test func dictionaryIsSeededOnceThenKept() throws {
        let files = tempFiles()
        #expect(try files.loadDictionary() == AppFiles.starterDictionary)
        files.saveDictionary([DictionaryEntry(word: "Only")])
        #expect(try files.loadDictionary() == [DictionaryEntry(word: "Only")])
    }

    @Test func starterListSpellsFreyaWithoutAJ() {
        let words = AppFiles.starterDictionary.map(\.word)
        #expect(words.contains("Freya") && !words.contains("Freyja"))
        // No rule may turn the right spelling into a different one.
        #expect(!AppFiles.starterDictionary.contains { $0.heardAs.contains("freya") })
        let fixed = DictionaryCorrector(entries: AppFiles.starterDictionary).apply(to: "I asked freya and Freyja about it")
        #expect(fixed.text == "I asked Freya and Freya about it")
    }

    @Test func damagedDictionaryIsReportedNotSilentlyEmptied() throws {
        let files = tempFiles()
        try Data(#"{"entries": [ {"word": "Oops" "heardAs": []} ]}"#.utf8).write(to: files.dictionaryURL)
        #expect(throws: (any Error).self) { try files.loadDictionary() }
    }
}
