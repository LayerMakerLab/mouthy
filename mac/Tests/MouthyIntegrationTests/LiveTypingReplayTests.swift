import Foundation
import Testing
@testable import MouthyCore
@testable import MouthyKit

// MOUTHY_TEST_LIVE_TYPING=1 swift test -c release -Xswiftc -enable-testing --filter liveTypingReplay
// "Type as I speak" on real recognition: a monologue synthesized with `say` plays into LiveTranscriber at real time,
// every guess goes through `LiveTyping` as the app feeds it (a phrase is typed when the pass at its pause has it),
// and the edits are played into a string like key presses into a field. Fails if anything is taken back while
// speaking or more than `LiveTyping.nearRemoved` characters at the stop, if the field does not end with the words of
// the finished text (two may be as a pause heard them), or if a phrase stands in
// the field more than a median 3 s after its last word. It also prints how far the field trails the voice, each
// word's end taken from the recognizer's own token times.
// `MOUTHY_LIVE_TYPING_AUDIO=<16 kHz mono wav>` replays a recording of a person instead (keep such recordings out of
// the repository): the passes of a real voice disagree with each other now and then, so the field then holds what
// the pauses' passes heard and is not compared with the finished text.
// `MOUTHY_LIVE_WORDS=1` replays with "Show words instantly" (the streaming recognizer shows the newest words; needs
// its model on this Mac): then a word must stand in its place a median 0.2 s after it was said at most, and up to half
// of the typed characters may be taken back (every pause rewrites its stretch with capitals and punctuation).
// `MOUTHY_LIVE_TYPING_VOCAB=<words, one per line>` switches on the vocabulary pass, as custom words do in the app;
// `MOUTHY_LIVE_PREVIEW_MS`, `MOUTHY_LIVE_PRIORITY=utility` and `MOUTHY_LIVE_SETTLE_MS` replay older settings. `MOUTHY_LIVE_TYPING_OUT=<tsv>` writes every guess and the field after it. No personal audio; needs the
// cached Parakeet model.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_LIVE_TYPING"] == "1"))
func liveTypingReplay() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-live-typing-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let script = ProcessInfo.processInfo.environment["MOUTHY_LIVE_TYPING_TEXT"] ?? "Okay so the next thing I want to do is move the settings page into its own window, and then we should check that the update feed still works. After that, pick up oat milk and the good bread on the way home. I think that covers everything for today."
    // `MOUTHY_LIVE_TYPING_AUDIO=<16 kHz mono wav>`: a recording of a person instead of the synthetic voice. A real
    // voice makes the fast guesses and the passes disagree far more often than a synthetic one does.
    let recording = ProcessInfo.processInfo.environment["MOUTHY_LIVE_TYPING_AUDIO"]
    let speech = Corpus.level(try recording.map { try Corpus.read(URL(fileURLWithPath: $0)) } ?? Corpus.say(script, in: folder), Corpus.speech)
    let audio = Corpus.room(Corpus.silence(0.4) + speech + Corpus.silence(1.0))
    try await ParakeetRecognizer.shared.prepare(download: false) { _ in }
    _ = try await ParakeetRecognizer.shared.transcribe(samples: Array(audio.prefix(32_000)), boost: true)
    await VoiceActivity.shared.prepare()
    // Custom words switch on the slower vocabulary pass, as most people who dictate daily have.
    if let vocabulary = ProcessInfo.processInfo.environment["MOUTHY_LIVE_TYPING_VOCAB"] { await ParakeetRecognizer.shared.setVocabulary(vocabulary) }
    for (label, boost) in [("plain", false), ("vocabulary", true)] {
        var times: [Int] = []
        for seconds in [2, 5, 10] {
            let piece = Array(audio.prefix(seconds * 16_000))
            let began = ContinuousClock.now
            _ = try await ParakeetRecognizer.shared.transcribe(samples: piece, boost: boost)
            times.append(LiveTranscriber.milliseconds(began.duration(to: .now)))
        }
        print("live typing: a \(label) pass over 2, 5 and 10 s of audio takes \(times) ms")
    }
    if let interval = ProcessInfo.processInfo.environment["MOUTHY_LIVE_PREVIEW_MS"].flatMap(Int.init) { LiveTranscriber.shortestPreviewInterval = interval * 16 }
    if ProcessInfo.processInfo.environment["MOUTHY_LIVE_PRIORITY"] == "utility" { LiveTranscriber.livePriority = .utility }
    if let settle = ProcessInfo.processInfo.environment["MOUTHY_LIVE_SETTLE_MS"].flatMap(Int.init) { LiveTyper.settleAfter = .milliseconds(settle) }
    let spoken = try await ParakeetRecognizer.shared.timedWords(samples: audio)
    var recorded = 0
    // "Show words instantly": the streaming recognizer shows the newest words (needs its model on this Mac).
    var stream: LiveTranscriber.Stream?
    if ProcessInfo.processInfo.environment["MOUTHY_LIVE_WORDS"] == "1" {
        #expect(await LiveWords.shared.prepare(), "download the model in Settings → Writing → Show words instantly")
        stream = { samples, restart in await LiveWords.shared.hear(samples, restart: restart) }
    }
    let live = LiveTranscriber(decode: { samples, boost in try await ParakeetRecognizer.shared.transcribe(samples: samples, boost: boost) },
                               decodeAfter: ParakeetRecognizer.decodeAfter, decodeAround: ParakeetRecognizer.decodeAround, hearsSpeech: VoiceActivity.hearsSpeech, speakers: nil, stream: stream,
                               count: { recorded }, read: { Array(audio[$0.clamped(to: 0..<recorded)]) })
    live.quickFirst = stream != nil && ProcessInfo.processInfo.environment["MOUTHY_LIVE_TYPING_VOCAB"] != nil && ProcessInfo.processInfo.environment["MOUTHY_LIVE_QUICK"] != "0"
    let started = ContinuousClock.now
    func now() -> Int { LiveTranscriber.milliseconds(started.duration(to: .now)) }
    var typing = LiveTyping(), field = "", typedCharacters = 0, deletedCharacters = 0, guesses = 0
    // As the app sets it: the passes mark the pauses unless the streaming recognizer writes the words.
    typing.settlesAtPauses = stream == nil
    var lines: [String] = [], lastGuess = 0, settled = true, gap = 0
    /// Every guess and every state of the field, in words, with its time.
    var guessed: [(at: Int, words: [String])] = [], shown: [(at: Int, words: [String])] = []
    func words(_ text: String) -> [String] { text.split(separator: " ").map { LiveTyping.plain(String($0)) } }
    func play(_ edits: [LiveTyping.Edit]) {
        for edit in edits {
            switch edit {
            case .delete(let count): field.removeLast(count); deletedCharacters += count
            case .type(let text): field += text; typedCharacters += text.count
            }
        }
        shown.append((now(), words(field)))
    }
    // `MOUTHY_LIVE_TYPING_SHAPE=1`: every guess and the finished text go through the app's own shaping (fillers,
    // the custom-word guard, spoken marks), as "Type as I speak" does.
    let shapes = ProcessInfo.processInfo.environment["MOUTHY_LIVE_TYPING_SHAPE"] == "1"
    let vocabulary = ProcessInfo.processInfo.environment["MOUTHY_LIVE_TYPING_VOCAB"] ?? ""
    func shaped(_ text: String, live: Bool) -> String {
        shapes ? DictationText.shape(text, code: false, replacements: [], punctuation: true, removeFillers: true, vocabulary: vocabulary, live: live) : text
    }
    live.onText = { raw in
        let text = shaped(raw, live: true)
        // The pause rule `LiveTyper` applies: twice the gap between guesses, at least `settleAfter`.
        gap = guesses == 0 ? 0 : min(now() - lastGuess, 1_000)
        guesses += 1; lastGuess = now(); settled = false
        guessed.append((now(), words(text)))
        play(typing.hear(text, firm: live.streams, pause: live.textPause))
        lines.append("\(now())\tguess\t\(text)\n\(now())\tfield\t\(field)" + (live.textPause.map { "\n\(now())\tatpause\t\($0 == .talkedOn ? "talkedon" : "")" } ?? ""))
    }
    let cpu = LiveBenchmark.cpuSeconds()
    while recorded < audio.count {
        let step = min(audio.count - recorded, 1_600)
        recorded += step
        live.tick()
        // Real time by the clock: a fixed sleep per step runs about 4% late, and every time measured against the
        // audio with it (half a second by the end of this clip).
        let due = recorded / 16 - now()
        if due > 0 { try await Task.sleep(for: .milliseconds(due)) }
        if !typing.settlesAtPauses, !settled, now() - lastGuess >= max(LiveTranscriber.milliseconds(LiveTyper.settleAfter), gap * 2) {
            settled = true
            play(typing.settle())
            lines.append("\(now())\tpause\t\(field)")
        }
    }
    let final = shaped(try await live.finish(audio), live: false)
    // What the person watched change while speaking, apart from the one correction at the stop.
    let deletedWhileSpeaking = deletedCharacters
    // And what was in the field then that the finished text writes differently: the words the stop has to correct.
    let typedBeforeTheStop = words(field)
    play(typing.finish(final).edits)
    let seconds = Double(audio.count) / 16_000
    let used = LiveBenchmark.cpuSeconds() - cpu
    // For each word of the finished text: how long after a guess first had everything up to it right the field had
    // it too.
    let finished = words(final)
    let lags: [Int] = finished.indices.compactMap { index in
        let upTo = finished[...index]
        guard let typed = shown.first(where: { $0.words.count > index && $0.words[...index] == upTo }) else { return nil }
        // From the guess since which every guess had it right: one that had it for a moment before (an ending the
        // recognizer made up that the person then happened to say) gave nothing to type.
        let before = guessed.prefix { $0.at <= typed.at }
        let wrong = before.lastIndex { !($0.words.count > index && $0.words[...index] == upTo) }
        guard let heard = before.dropFirst((wrong ?? -1) + 1).first else { return nil }
        return max(0, typed.at - heard.at)
    }
    let worst = lags.max() ?? 0, median = lags.isEmpty ? 0 : lags.sorted()[lags.count / 2]
    // And how long after each word was spoken (its end by the recognizer's own token times, which are good to about
    // a tenth of a second) the field had it: what the person feels.
    let behind: [Int] = finished.indices.compactMap { index in
        guard index < spoken.count, LiveTyping.plain(spoken[index].word) == finished[index],
              let typed = shown.first(where: { $0.words.count > index && $0.words[...index] == finished[...index] }) else { return nil }
        return typed.at - Int(spoken[index].end * 1000)
    }.sorted()
    // With the streaming recognizer: when any word first stood in each place (it writes one word in twenty wrong
    // until the next pass).
    let inPlace: [Int] = finished.indices.compactMap { index in
        guard index < spoken.count, let typed = shown.first(where: { $0.words.count > index }) else { return nil }
        return typed.at - Int(spoken[index].end * 1000)
    }.sorted()
    let behindLine = behind.isEmpty ? "" : ", behind the voice: median \(behind[behind.count / 2]) ms, 90% within \(behind[behind.count * 9 / 10]) ms, worst \(behind.last!) ms (\(behind.count) words)"
    let summary = "live typing: \(guesses) guesses in \(String(format: "%.1f", seconds)) s (one every \(Int(seconds * 1000) / max(1, guesses)) ms), typed \(typedCharacters), took back \(deletedWhileSpeaking) while speaking and \(deletedCharacters - deletedWhileSpeaking) at the stop, a word reaches the field after a guess has it: median \(median) ms, worst \(worst) ms\(behindLine), CPU \(String(format: "%.0f", used / seconds * 100))% of one core"
    print(summary)
    if stream != nil, !inPlace.isEmpty {
        print("live typing: with the streaming recognizer a word stands in its place a median \(inPlace[inPlace.count / 2]) ms after it was said, 90% within \(inPlace[inPlace.count * 9 / 10]) ms, worst \(inPlace.last!) ms")
    }
    lines.append("FINAL\t\(final)"); lines.append("FIELD\t\(field)"); lines.append(summary)
    lines.append("SPOKEN\t" + spoken.map { "\($0.word)@\(Int($0.end * 1000))" }.joined(separator: " "))
    if let out = ProcessInfo.processInfo.environment["MOUTHY_LIVE_TYPING_OUT"] {
        try lines.joined(separator: "\n").appending("\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
    if stream != nil {
        #expect(field == final)
        #expect(live.streams, "the streaming recognizer stopped")
        #expect(deletedCharacters * 2 <= typedCharacters, "took back \(deletedCharacters) of \(typedCharacters) typed characters")
        #expect(!inPlace.isEmpty && inPlace[inPlace.count / 2] <= 200, "a word stood in its place a median \(inPlace.isEmpty ? -1 : inPlace[inPlace.count / 2]) ms after it was said")
    } else {
        // Nothing is taken back while speaking: a phrase is typed when its pause was heard, and stays. At the stop
        // only removed words near the end are (`LiveTyping.nearRemoved`).
        #expect(deletedWhileSpeaking == 0, "took back \(deletedWhileSpeaking) characters while speaking")
        #expect(deletedCharacters - deletedWhileSpeaking <= LiveTyping.nearRemoved, "took back \(deletedCharacters - deletedWhileSpeaking) characters at the stop")
        // With the synthetic voice the passes nearly always hear the same words, so the field ends with the finished
        // text's words, but for a settled word the stop's pass heard differently ("the rose" for "the row"). A
        // person's voice gives more of those, so recordings are not compared.
        if recording == nil {
            let typedWords = field.split(separator: " ").map(LiveTyping.written), wanted = final.split(separator: " ").map(LiveTyping.written)
            #expect(typedWords.count == wanted.count && zip(typedWords, wanted).filter { $0.0 != $0.1 }.count <= 2, "the field does not end with the finished text's words")
        }
        print("live typing: \(typedBeforeTheStop.count) words in the field before the stop, \(finished.count) in the finished text")
    }
    if stream != nil {
        #expect(worst <= 1_500 && median <= 250, "a word reached the field \(worst) ms (median \(median) ms) after a guess had it")
    } else if !inPlace.isEmpty {
        // What the person feels: a phrase stands in the field a moment after its last word (the pause that is heard
        // after 0.2 s, and the pass over it), and the words before it waited for that.
        let ends = finished.indices.filter { $0 < spoken.count && ($0 + 1 == spoken.count || spoken[$0 + 1].end - spoken[$0].end > 0.7) }
        let afterPhrase: [Int] = ends.compactMap { index in shown.first { $0.words.count > index }.map { $0.at - Int(spoken[index].end * 1000) } }.sorted()
        print("live typing: a word stands in its place a median \(inPlace[inPlace.count / 2]) ms after it was said, 90% within \(inPlace[inPlace.count * 9 / 10]) ms, worst \(inPlace.last ?? 0) ms; the last word of a phrase a median \(afterPhrase.isEmpty ? -1 : afterPhrase[afterPhrase.count / 2]) ms, 90% within \(afterPhrase.isEmpty ? -1 : afterPhrase[afterPhrase.count * 9 / 10]) ms (\(afterPhrase.count) phrases)")
        if recording == nil {
            // (The synthetic voice's pauses are short, so the person "talks on" after most of them: about 2.4 s
            // and 2.6 s in two monologues, 2026-11-26.)
            #expect(!afterPhrase.isEmpty && afterPhrase[afterPhrase.count / 2] <= 3_000 && inPlace[inPlace.count / 2] <= 3_000,
                    "a phrase stood in the field a median \(afterPhrase.isEmpty ? -1 : afterPhrase[afterPhrase.count / 2]) ms after its last word, a word \(inPlace[inPlace.count / 2]) ms")
        }
    }
}
