import Testing
import Foundation
@testable import MouthyCore

@Test func spokenPunctuationAttachesAndCases() {
    #expect(SpokenPunctuation.apply("hello comma how are you question mark") == "hello, how are you?")
    #expect(SpokenPunctuation.apply("Done period Next item exclamation point") == "Done. Next item!")
    #expect(SpokenPunctuation.apply("Dear Sam colon Thanks") == "Dear Sam: thanks")
    #expect(SpokenPunctuation.apply("first full stop second") == "first. Second")
}
@Test func spokenPunctuationRemovesRecognizerDuplicates() {
    #expect(SpokenPunctuation.apply("Hello, comma. Next") == "Hello, next")
    #expect(SpokenPunctuation.apply("Wait. Period. Then") == "Wait. Then")
}
@Test func spokenPunctuationKeepsOrdinaryUseAndNames() {
    #expect(SpokenPunctuation.apply("It was a period in history") == "It was a period in history")
    #expect(SpokenPunctuation.apply("the trial period ends") == "the trial period ends")
    #expect(SpokenPunctuation.apply("Thanks comma I will call comma Tuesday works") == "Thanks, I will call, Tuesday works")
}
@Test func spokenLineBreaksCapitalize() {
    #expect(SpokenPunctuation.apply("one new line two new paragraph three") == "one\nTwo\n\nThree")
    #expect(TextPipeline.process("Café new paragraph hello", replacements: [], punctuation: true) == "Café\n\nHello")
}
/// A live guess shows a spoken mark only once the word after it is whole, which is when another word follows: until
/// then the text stops before the mark (the finished text has everything).
@Test func spokenJoinersHoldBackAMarkUntilItsNextWordIsWhole() {
    func live(_ text: String, vocabulary: String = "") -> String { SpokenJoiners.apply(text, vocabulary: vocabulary, open: true) }
    #expect(live("name it maple dash") == "name it maple" && SpokenJoiners.apply("name it maple dash") == "name it maple dash")
    // The last word of a guess may still grow: "k" into "kiwi", "co" into "come", "i" into "is".
    #expect(live("name it maple dash design") == "name it maple" && live("name it maple dash k") == "name it maple")
    #expect(live("name it maple dash design is") == "name it maple-design is")
    #expect(live("see example dot") == "see example" && live("see example dot co") == "see example")
    #expect(live("see example dot com today") == "see example.com today")
    #expect(live("type slash") == "type" && live("type slash help") == "type" && live("type slash help now") == "type /help now")
    #expect(live("user underscore") == "user" && live("user underscore name") == "user" && live("user underscore name is") == "user_name is")
    #expect(live("git commit dash m") == "git commit" && live("git commit dash m fix") == "git commit -m fix")
    #expect(live("the dot env") == "the" && live("the dot env file") == "the .env file")
    // Two dashes wait for the word after them, and for that word to be whole.
    #expect(live("run it with dash") == "run it with" && live("run it with dash dash") == "run it with")
    #expect(live("run it with dash dash help") == "run it with" && live("run it with dash dash help now") == "run it with --help now")
    // The mark a pause puts after the guess does not make it a word yet.
    #expect(live("name it maple dash.") == "name it maple" && live("run it with dash dash.") == "run it with" && live("see example dot,") == "see example")
    // Also where it will turn out to be a word: that shows with the words after it, or at the stop.
    #expect(live("that was a mad dash") == "that was a mad" && live("that was a mad dash for") == "that was a mad")
    #expect(live("that was a mad dash for the") == "that was a mad dash for the")
    #expect(live("connect the dot") == "connect the" && live("maple\ndash") == "maple" && live("maple dash dot") == "maple")
    // One of the person's own words is never a mark, so it never waits.
    #expect(live("I use Dash", vocabulary: "Dash") == "I use Dash")
    // Each step of an address is typed once the word after it is whole, and stays.
    #expect(live("open www dot example") == "open www" && live("open www dot example dot") == "open www.example")
    #expect(live("open www dot example dot com") == "open www.example" && live("open www dot example dot com today") == "open www.example.com today")
    // What is shown is always the start of what the same words give in the end.
    for text in ["name it maple dash design is ready", "open www dot example dot com today", "git commit dash m fix it", "run dash dash help now"] {
        let words = text.split(separator: " ")
        for count in 1...words.count {
            #expect(SpokenJoiners.apply(text).hasPrefix(live(words[..<count].joined(separator: " "))), "\(count) words of \(text)")
        }
    }
}

@Test func aSpokenCommandShowsOnlyOnceTheDictationIsFinished() {
    // The whole dictation is the command. A live guess cannot know that nothing follows, so it shows nothing while
    // the words so far could be one, and words once they cannot.
    #expect(SpokenJoiners.apply("Slash clear.") == "/clear")
    #expect(SpokenJoiners.apply("Slash clear.", open: true) == "")
    #expect(SpokenJoiners.apply("slash code dash review", open: true) == "" && SpokenJoiners.apply("slash code dash review") == "/code-review")
    #expect(SpokenJoiners.apply("slash com dash is", open: true) == "" && SpokenJoiners.apply("slash com dash is run or example") == "slash com dash is run or example")
    #expect(SpokenJoiners.apply("Slash spending by half and", open: true) == "Slash spending by half and")
    #expect(SpokenJoiners.apply("Slash spending by half.") == "Slash spending by half.")
    // The last word of a guess may still grow into a mark: nothing shows before it has.
    #expect(SpokenJoiners.apply("slash user under", open: true) == "" && SpokenJoiners.apply("slash user underscore name") == "/user_name")
    // A mark that does not join makes it no command.
    #expect(SpokenJoiners.apply("slash to dash do") == "slash to dash do" && SpokenJoiners.apply("Slash budgets, dash hopes.") == "Slash budgets, dash hopes.")
}

/// What a live guess shows is the start of what the finished text shows (its last shown word aside, which may still
/// grow): typed live, nothing of it is taken back. Random texts that begin
/// like a command or like a sentence, every prefix of each, with the last word whole and cut short.
@Test func aLiveGuessNeverShowsWhatTheFinishedTextTakesBack() {
    struct Random {
        var state: UInt64
        mutating func next(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(count))
        }
    }
    let vocabulary = ["slash", "slash", "clear", "code", "review", "user", "name", "dash", "dash", "hyphen", "underscore", "underscore", "dot",
                      "to", "the", "is", "it", "spending", "half", "com", "md", "m", "type", "and", "or", "example", "7"]
    var random = Random(state: 11), broken: [String] = [], commands = 0
    for _ in 0..<4000 {
        var spoken = (0..<(2 + random.next(6))).map { _ in vocabulary[random.next(vocabulary.count)] }
        if random.next(3) > 0 { spoken[0] = "slash" }
        let finished = SpokenJoiners.apply(spoken.joined(separator: " ") + ".")
        if finished.hasPrefix("/") { commands += 1 }
        for count in 1...spoken.count {
            for cutShort in [false, true] {
                var heard = Array(spoken[..<count])
                if cutShort { guard heard[count - 1].count > 2 else { continue }; heard[count - 1] = String(heard[count - 1].prefix(2)) }
                for pause in cutShort ? [""] : ["", "."] {
                    let shown = SpokenJoiners.apply(heard.joined(separator: " ") + pause, open: true).split(separator: " ").map(String.init)
                    // Everything shown before the last word is how the finished text begins (a later word may still
                    // be joined onto it: "review" before "review_code").
                    if !finished.hasPrefix(shown.dropLast().joined(separator: " ")) {
                        broken.append("\(heard.joined(separator: " "))\(pause) → \(shown.joined(separator: " ")) | \(finished)")
                    }
                }
            }
        }
    }
    #expect(commands > 150, "\(commands)")
    #expect(broken.isEmpty, "\(broken.count) broken, first: \(broken.prefix(6).joined(separator: " ;; "))")
}
@Test func modeResolutionFollowsPriority() {
    var app = DictationMode(name: "Slack"); app.apps = ["com.tinyspeck.slackmacgap"]
    var site = DictationMode(name: "GitHub"); site.websites = ["github.com"]
    var keyed = DictationMode(name: "Keyed"); keyed.apps = ["com.tinyspeck.slackmacgap"]
    let modes = [app, site, keyed]
    #expect(ModeResolver.startMode(modes, shortcutMode: keyed.id, url: "https://github.com/x", bundleID: "com.tinyspeck.slackmacgap")?.name == "Keyed")
    #expect(ModeResolver.startMode(modes, shortcutMode: nil, url: "https://gist.github.com/x", bundleID: "com.tinyspeck.slackmacgap")?.name == "GitHub")
    #expect(ModeResolver.startMode(modes, shortcutMode: nil, url: "https://notgithub.com", bundleID: "com.tinyspeck.slackmacgap")?.name == "Slack")
    #expect(ModeResolver.startMode(modes, shortcutMode: nil, url: nil, bundleID: "com.apple.TextEdit") == nil)
}
@Test func triggerWordSelectsModeAndIsStripped() {
    var email = DictationMode(name: "Email"); email.triggerWord = "email"
    var emailFormal = DictationMode(name: "Formal"); emailFormal.triggerWord = "email formal"
    let modes = [email, emailFormal]
    let plain = ModeResolver.trigger(in: "Email, thanks for the update.", modes: modes)
    #expect(plain?.0.name == "Email" && plain?.1 == "Thanks for the update.")
    #expect(ModeResolver.trigger(in: "email formal dear team", modes: modes)?.0.name == "Formal")
    #expect(ModeResolver.trigger(in: "Emails are piling up", modes: modes) == nil)
}
@Test func modesDecodeFromOlderSettings() throws {
    let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
    #expect(decoded.modes.isEmpty)
    let mode = try JSONDecoder().decode(DictationMode.self, from: Data(#"{"name":"Notes"}"#.utf8))
    #expect(mode.output == .insert && mode.engine == nil)
}
@Test func accumulatorSplitsWithoutDuplicates() {
    var a = TranscriptAccumulator()
    a.accept("First part.", isFinal: true); a.accept("second", isFinal: false)
    #expect(a.takeFinalized() == "First part.")
    a.accept("Second part.", isFinal: true)
    #expect(a.preview == "Second part." && a.finalText == "Second part.")
}
@Test func pauseDotsNeverReachTheText() {
    var a = TranscriptAccumulator()
    a.accept("...", isFinal: true); a.accept("…", isFinal: false)
    #expect(a.preview.isEmpty && a.finalText.isEmpty)
    a.accept("That is fast.", isFinal: true)
    #expect(a.finalText == "That is fast.")
    #expect(TextPipeline.process("......., That is like insanely fast now.", replacements: [], punctuation: true) == "That is like insanely fast now.")
    #expect(TextPipeline.process("... Oh, but what's with the dots?", replacements: [], punctuation: false) == "Oh, but what's with the dots?")
}
