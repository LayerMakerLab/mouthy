import Foundation
import Testing
@testable import MouthyKit
@testable import MouthyCore

// MOUTHY_TEST_ACCURACY=1 swift test -c release -Xswiftc -enable-testing --filter accuracyCorpus
// Scores what a person would see typed against what they meant: each script is spoken by several macOS voices
// with its pauses (and Enter presses), recognized live at real time through LiveTranscriber like a Parakeet dictation,
// shaped by the same text rules as AppModel (Natural mode, default settings), and compared with the exact expected text.
// A pause inside a sentence is `say`'s [[slnc ms]] in one utterance: fragments spoken apart each end with a sentence's fall
// in pitch, which no person pausing mid-sentence makes.
// Word errors are an edit distance over the words alone; format errors are the extra token edits that punctuation and
// capitals cause. The whole-file pass is scored beside it, so a live-only error points at the joins, not the model.
// MOUTHY_ACCURACY_ONLY=<name part>, MOUTHY_ACCURACY_VOICES=<v1|v2> (default: the system voice, Eddy and Flo),
// MOUTHY_ACCURACY_VOCAB=<words, one per line> (custom words, as in Settings), MOUTHY_ACCURACY_OUT=<file.tsv>.
// Fails only when MOUTHY_ACCURACY_GATE=1: any word error, or any format error, in live text.

enum AccuracyCorpus {
    enum Part { case say(String), pause(Double), enter }
    struct Script {
        let name: String
        let parts: [Part]
        /// Accepted results; parts sent by Enter are joined with " ⏎ ".
        let expected: [String]
        init(_ name: String, _ parts: [Part], _ expected: String...) { self.name = name; self.parts = parts; self.expected = expected }
        init(_ name: String, say text: String, _ also: String...) { self.init(name, [.say(text)], text, also) }
        private init(_ name: String, _ parts: [Part], _ first: String, _ rest: [String]) { self.name = name; self.parts = parts; expected = [first] + rest }
    }
    static func s(_ text: String) -> Part { .say(text) }
    static func p(_ seconds: Double) -> Part { .pause(seconds) }

    static let scripts: [Script] = [
        Script("plain sentence", say: "I'll pick up the groceries on the way home."),
        Script("question", say: "Can you send me the report by Friday?"),
        Script("short reply", say: "Sounds good."),
        Script("yes thanks", say: "Yes, thank you.", "Yes. Thank you."),
        Script("names and places", say: "Sarah and James are flying to Chicago next Tuesday."),
        Script("contractions", say: "I don't think it's ready, and we can't ship it yet.", "I don't think it's ready and we can't ship it yet."),
        Script("list", say: "We need eggs, milk, butter, and two loaves of bread.", "We need eggs, milk, butter and two loaves of bread.",
               "We need eggs, milk, butter, and 2 loaves of bread.", "We need eggs, milk, butter and 2 loaves of bread."),
        Script("greeting and plan", say: "Hi Mark, thanks for the update. I'll review the draft tonight and get back to you tomorrow.",
               "Hi Mark, thanks for the update. I will review the draft tonight and get back to you tomorrow."),
        Script("reported speech", say: "She said the shipment would be late."),
        Script("acronyms", say: "Send the PDF to the HR team by noon."),
        Script("hyphens", say: "It's a well-known issue with the third-party driver.", "It's a well known issue with the third party driver."),
        Script("time", [s("The call is at three thirty tomorrow.")], "The call is at 3:30 tomorrow."),
        Script("time to the minute", [s("It's eleven fifty eight right now.")], "It's 11:58 right now."),
        Script("time to wake", [s("Wake me at six forty five tomorrow.")], "Wake me at 6:45 tomorrow."),
        Script("time on the hour", [s("The call is at ten a.m. tomorrow.")], "The call is at 10 a.m. tomorrow."),
        Script("time by the clock", [s("Let's do one o'clock.")], "Let's do 1 o'clock."),
        Script("counting is no time", [s("One, two, three, go.")], "1, 2, 3, go.", "1, 2, 3, go!", "One, two, three, go."),
        Script("money and percent", [s("The price went up fifteen percent to forty nine dollars.")],
               "The price went up 15% to $49.", "The price went up fifteen percent to forty-nine dollars.", "The price went up 15 percent to $49."),
        Script("date", [s("Her birthday is on March fourth.")], "Her birthday is on March 4th.", "Her birthday is on March fourth.", "Her birthday is on March 4."),
        Script("counts", [s("Order twelve spools and two nozzles.")], "Order 12 spools and 2 nozzles.", "Order twelve spools and two nozzles."),
        Script("year", [s("We started the company in twenty twenty five.")], "We started the company in 2025."),
        Script("mid-sentence pause 0.5 s", [s("I think we should move the meeting [[slnc 500]] to Thursday afternoon.")],
               "I think we should move the meeting to Thursday afternoon."),
        Script("mid-sentence pause 0.8 s", [s("If the package arrives today [[slnc 800]] please leave it by the back door.")],
               "If the package arrives today, please leave it by the back door.", "If the package arrives today please leave it by the back door."),
        Script("pauses around I", [s("Yesterday [[slnc 500]] I went to the hardware store [[slnc 500]] and I found the part.")],
               "Yesterday I went to the hardware store and I found the part.", "Yesterday, I went to the hardware store and I found the part.",
               "Yesterday, I went to the hardware store, and I found the part.", "Yesterday I went to the hardware store, and I found the part."),
        Script("question split by a pause", [s("Do you want to grab lunch [[slnc 600]] or should we wait until later?")],
               "Do you want to grab lunch or should we wait until later?", "Do you want to grab lunch, or should we wait until later?"),
        Script("two sentences", [s("The printer finished the first batch."), p(1.2), s("Now it needs to cool down.")],
               "The printer finished the first batch. Now it needs to cool down."),
        Script("statement then question", [s("I looked at the numbers this morning."), p(1.0), s("Do they still look right to you?")],
               "I looked at the numbers this morning. Do they still look right to you?"),
        Script("question then answer", [s("What time works best for you?"), p(1.2), s("I'm free after two.")],
               "What time works best for you? I'm free after two.", "What time works best for you? I'm free after 2."),
        Script("sentence opens with a number", [s("The first batch is done."), p(1.0), s("Twenty more are in the queue.")],
               "The first batch is done. Twenty more are in the queue.", "The first batch is done. 20 more are in the queue."),
        Script("fillers", [s("So um I was thinking we could uh try the new layout.")],
               "So I was thinking we could try the new layout.", "So, I was thinking we could try the new layout."),
        Script("scratch that", [s("Send it to the team."), p(0.6), s("Scratch that."), p(0.5), s("Send it to the whole company.")],
               "Send it to the whole company."),
        Script("monologue", [s("Okay, here's the plan for this week."), p(0.9), s("On Monday I'll finish the new stand design [[slnc 350]] and print a test piece."), p(0.9), s("If it fits, I'll order more filament on Tuesday."), p(0.9),
                             s("Then I want to photograph everything, [[slnc 300]] write the listings, [[slnc 300]] and put them up by Friday night."), p(0.9), s("Does that sound realistic?")],
               "Okay, here's the plan for this week. On Monday I'll finish the new stand design and print a test piece. If it fits, I'll order more filament on Tuesday. Then I want to photograph everything, write the listings, and put them up by Friday night. Does that sound realistic?",
               "OK, here's the plan for this week. On Monday I'll finish the new stand design and print a test piece. If it fits, I'll order more filament on Tuesday. Then I want to photograph everything, write the listings, and put them up by Friday night. Does that sound realistic?",
               "Okay, here's the plan for this week. On Monday, I'll finish the new stand design and print a test piece. If it fits, I'll order more filament on Tuesday. Then I want to photograph everything, write the listings, and put them up by Friday night. Does that sound realistic?"),
        Script("custom words", say: "Open the project in Xcode and push it to GitHub."),
        Script("common word near a custom word", say: "The new model runs faster on the laptop."),
        Script("assistant names", say: "Ask Claude to review the code before Codex merges it."),
        Script("Enter between sentences", [s("Please check the order status."), .enter, p(0.4), s("Then email the customer.")],
               "Please check the order status. ⏎ Then email the customer."),
        Script("Enter right after a word", [s("First message goes here."), p(0.15), .enter, p(0.6), s("And this is the second one.")],
               "First message goes here. ⏎ And this is the second one."),
    ]

    static func audio(_ script: Script, voice: String?, in folder: URL) throws -> (samples: [Float], enters: [Int]) {
        var samples: [Float] = Corpus.silence(0.3), enters: [Int] = []
        for part in script.parts {
            switch part {
            case .say(let text): samples += Corpus.level(try Corpus.say(text, voice: voice, in: folder), Corpus.speech)
            case .pause(let seconds): samples += Corpus.silence(seconds)
            case .enter: enters.append(samples.count)
            }
        }
        return (Corpus.room(samples + Corpus.silence(0.2)), enters)
    }

    /// Tokens as typed (punctuation and case kept); words alone for the word score.
    static func tokens(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
    static func distance(_ a: [String], _ b: [String]) -> Int {
        var row = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var previous = row[0]; row[0] = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return a.isEmpty ? b.count : row[b.count]
    }
    struct Score { let words: Int; let format: Int; let total: Int; let expected: String }
    /// The accepted text closest to `text`.
    static func score(_ text: String, against accepted: [String]) -> Score {
        accepted.map { expected in
            let words = distance(Corpus.words(expected), Corpus.words(text))
            let all = distance(tokens(expected), tokens(text))
            return Score(words: words, format: max(0, all - words), total: Corpus.words(expected).count, expected: expected)
        }.min { ($0.words, $0.format) < ($1.words, $1.format) }!
    }
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_ACCURACY"] == "1"))
func accuracyCorpus() async throws {
    let env = ProcessInfo.processInfo.environment
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-accuracy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let voices: [String?] = env["MOUTHY_ACCURACY_VOICES"].map { $0.split(separator: "|").map { String($0) } }
        ?? [nil, "Eddy (English (US))", "Flo (English (US))"]
    let vocabulary = env["MOUTHY_ACCURACY_VOCAB"] ?? ""
    let only = env["MOUTHY_ACCURACY_ONLY"]
    var config = Preferences()
    config.vocabulary = vocabulary
    await ParakeetRecognizer.shared.setVocabulary(vocabulary)
    try await ParakeetRecognizer.shared.prepare(download: false) { _ in }
    await VoiceActivity.shared.prepare()
    var rows: [String] = ["voice\tscript\tlive_word_errors\tlive_format_errors\twhole_word_errors\twhole_format_errors\twords\texpected\tlive\twhole"]
    var liveWords = 0, liveFormat = 0, wholeWords = 0, wholeFormat = 0, total = 0, exact = 0, runs = 0
    for script in AccuracyCorpus.scripts where only.map({ script.name.contains($0) }) ?? true {
        for voice in voices {
            let (audio, enters) = try AccuracyCorpus.audio(script, voice: voice, in: folder)
            let shape = { (raw: String) in DictationText.shape(raw, code: false, config: config) }
            let live: String
            if enters.isEmpty {
                let url = folder.appendingPathComponent("\(UUID().uuidString).wav")
                try Corpus.write(audio, to: url)
                let result = try await LiveBenchmark.run(file: url, engine: .parakeet, vocabulary: vocabulary, stopDelays: [0], releaseDelays: [])
                live = shape(result.runs[0].text)
            } else {
                live = try await LiveSplit.run(audio, splits: enters, speakers: nil).map(shape).joined(separator: " ⏎ ")
            }
            let whole = shape(try await ParakeetRecognizer.shared.transcribe(samples: audio, boost: true))
            let l = AccuracyCorpus.score(live, against: script.expected)
            let w = AccuracyCorpus.score(whole, against: script.expected.map { $0.replacingOccurrences(of: " ⏎ ", with: " ") })
            liveWords += l.words; liveFormat += l.format; wholeWords += w.words; wholeFormat += w.format
            total += l.total; runs += 1
            if l.words == 0 && l.format == 0 { exact += 1 }
            let who = voice ?? "system"
            print("ACCURACY \(l.words == 0 && l.format == 0 ? "ok  " : "MISS") \(script.name) [\(who)]: live words \(l.words) format \(l.format) · whole words \(w.words) format \(w.format)")
            if l.words + l.format > 0 {
                print("ACCURACY   want:  \(l.expected)")
                print("ACCURACY   live:  \(live)")
                print("ACCURACY   whole: \(whole)")
            }
            rows.append([who, script.name, "\(l.words)", "\(l.format)", "\(w.words)", "\(w.format)", "\(l.total)", l.expected, live, whole].joined(separator: "\t"))
        }
    }
    print(String(format: "ACCURACY %d runs, %d exact · live: %d word errors (%.1f%% of %d words), %d format errors · whole file: %d word errors, %d format errors",
                 runs, exact, liveWords, 100 * Double(liveWords) / Double(max(1, total)), total, liveFormat, wholeWords, wholeFormat))
    if let out = env["MOUTHY_ACCURACY_OUT"] { try (rows.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8) }
    if env["MOUTHY_ACCURACY_GATE"] == "1" { #expect(liveWords == 0 && liveFormat == 0) }
}
