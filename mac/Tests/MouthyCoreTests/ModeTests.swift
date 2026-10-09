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
