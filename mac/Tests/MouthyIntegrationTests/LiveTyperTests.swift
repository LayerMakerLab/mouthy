import AppKit
import ApplicationServices
import Testing
@testable import MouthyCore
@testable import MouthyKit

// "Type as I speak" against the headless delivery target (scripts/delivery-target.swift): real key events, posted to
// that background process only, and real Accessibility reads of its text view. Nothing reaches the keyboard stream,
// the screen or the person's apps. `./scripts/test.sh --delivery` runs these with the paste tests.

/// The key events of a press carry the text, no modifier, and Mouthy's mark (so its own key tap does not take them
/// for the person typing). Builds the events only; nothing is posted.
@MainActor @Test func liveTypingKeyEventsCarryNoModifierAndMouthysMark() throws {
    let source = try #require(CGEventSource(stateID: .hidSystemState))
    let chunks = LiveTyper.presses([.type("The quick brown fox jumps over it")], from: "").compactMap(\.text)
    #expect(chunks.map(\.count) == [16, 15, 2])
    #expect(String(utf16CodeUnits: chunks.flatMap { $0 }, count: 33) == "The quick brown fox jumps over it")
    let modifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn, .maskAlphaShift]
    let typed = LiveTyper.keyEvents(0, text: chunks[0], source: source)
    let backspace = LiveTyper.keyEvents(51, text: nil, source: source)
    #expect(typed.map(\.type) == [.keyDown, .keyUp] && backspace.map(\.type) == [.keyDown, .keyUp])
    for event in typed + backspace {
        #expect(event.flags.intersection(modifiers).isEmpty)
        #expect(event.getIntegerValueField(.eventSourceUserData) == ReturnKeyTap.syntheticMarker)
    }
    #expect(backspace.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == 51 })
    var length = 0
    var units = [UniChar](repeating: 0, count: 20)
    typed[0].keyboardGetUnicodeString(maxStringLength: 20, actualStringLength: &length, unicodeString: &units)
    #expect(Array(units[..<length]) == chunks[0])
}

/// What Mouthy may take back from a field: its own typed characters, all of them there, the last at the cursor.
@MainActor @Test func liveTypingTakesBackOnlyCharactersTheFieldStillHolds() {
    // Smart quotes and a field's own capital are still Mouthy's words.
    #expect(LiveTyper.holds("Keep. don’t stop", " don't stop"))
    #expect(LiveTyper.holds("Hello there", "hello there"))
    // A terminal program's input box wraps a long line with its border and indent, or just a line break.
    #expect(LiveTyper.holds("│ > pick up oat milk and the │\n│   good bread", "pick up oat milk and the good bread"))
    #expect(LiveTyper.holds("pick up oat milk and the\ngood bread", "pick up oat milk and the good bread"))
    // Different words, or the person's own after them, are not.
    #expect(!LiveTyper.holds("hello their", "hello there"))
    #expect(!LiveTyper.holds("hello there and more", "hello there"))
    #expect(!LiveTyper.holds("hello there\n", "hello there"))
    #expect(!LiveTyper.holds("hello there ", "hello there"))
    // The field made the text shorter (two hyphens became a dash, two words one): a backspace for every typed
    // character would reach into what was there before.
    #expect(!LiveTyper.holds("git log —oneline", "git log --oneline"))
    #expect(!LiveTyper.holds("pick up icecream", "pick up ice cream"))
    // Marks alone prove nothing.
    #expect(!LiveTyper.holds("...", "..."))
    // Taking left words up again is stricter: the field's text must be the typed text itself.
    #expect(LiveTyper.same("I don’t know", "i don't know"))
    #expect(!LiveTyper.same("I went to the store, and bought milk", "I went to the store and bought milk"))
    #expect(!LiveTyper.same("the oat\nmilk", "the oat milk"))
}

/// A long edit goes out in runs of key presses that each end on a whole word, so one cut short by a focus change
/// never leaves half a word behind.
@MainActor @Test func liveTypingKeyPressesCanStopOnlyOnWholeWords() {
    let typed = "pick up the oat milk"
    let presses = LiveTyper.presses([.delete(8), .type("good bread and some extraordinarily long word")], from: typed)
    #expect(presses.prefix(8).allSatisfy { $0.key == 51 && $0.text == nil })
    // Taking "oat milk" back: whole after "milk", after its space, after "oat".
    #expect(presses.prefix(8).map(\.after) == ["pick up the oat mil", "pick up the oat mi", "pick up the oat m", "pick up the oat ", "pick up the oat", "pick up the oa", "pick up the o", "pick up the "])
    #expect(presses.prefix(8).map(\.whole) == [false, false, false, true, true, false, false, true])
    let texts = presses.dropFirst(8)
    #expect(texts.allSatisfy { $0.key == 0 && ($0.text?.count ?? 0) <= 16 })
    #expect(texts.map { String(utf16CodeUnits: $0.text ?? [], count: $0.text?.count ?? 0) } == ["good bread and ", "some ", "extraordinarily ", "long word"])
    #expect(texts.map(\.whole) == [true, true, true, true])
    #expect(texts.last?.after == "pick up the good bread and some extraordinarily long word")
    // A word longer than one key event carries is the only place a piece ends inside a word.
    let long = LiveTyper.presses([.type("supercalifragilisticexpialidocious yes")], from: "")
    #expect(long.map(\.whole) == [false, false, true])
}

extension Harness {
    /// Key presses go to the target process alone, never to the keyboard stream.
    func takeKeyPresses() {
        let pid = app.processIdentifier
        LiveTyper.post = { $0.postToPid(pid) }
    }
    func typer(smartFormatting: Bool = true, settlesAtPauses: Bool = false) -> LiveTyper {
        takeKeyPresses()
        return LiveTyper(shape: { $0 }, smartFormatting: smartFormatting, names: [], settlesAtPauses: settlesAtPauses)
    }
    /// Guesses arrive a fraction of a second apart, never in the same instant (one handed over while the last is
    /// still being typed replaces it).
    func say(_ typer: LiveTyper, _ guesses: String...) async {
        for guess in guesses {
            typer.hear(guess)
            try? await Task.sleep(for: .milliseconds(60))
        }
    }
    func preview(_ speech: FakeSpeech, _ guesses: String...) async {
        for guess in guesses {
            speech.onPreview?(guess)
            try? await Task.sleep(for: .milliseconds(60))
        }
    }
    func settled(_ expected: String) async -> String {
        for _ in 0..<60 where value != expected { try? await Task.sleep(for: .milliseconds(25)) }
        return value
    }
}

// Inside the paste tests' serialized suite: one target and one set of delivery seams at a time.
extension HeadlessDelivery {
@MainActor @Suite struct TypeAsISpeak {
    @Test func wordsAreTypedWhileTalkingCorrectedAndFinished() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("Keep this", cursor: 9)
        let typer = harness.typer()
        // Three guesses agree on four words; the endings the first two made up are never typed. (The last guess is
        // the four words themselves, so a slow step that lets the pause rule type it gives the same field.)
        await harness.say(typer, "And then we should have to do it.", "And then we should check that the feed.", "And then we should.")
        #expect(await harness.settled("Keep this and then we should") == "Keep this and then we should")
        // (The same guess each time: typed words no longer change, so a slow step that lets the pause rule type an
        // earlier guess must find the same words there.)
        await harness.say(typer, "And then we should check that the feed still works, after that.", "And then we should check that the feed still works, after that.",
                          "And then we should check that the feed still works, after that.")
        #expect(await harness.settled("Keep this and then we should check that the feed still works, after that")
                == "Keep this and then we should check that the feed still works, after that")
        let outcome = await typer.finish("And then we should check that the feed still works. After that, pick up milk.")
        #expect(outcome == .typed(rest: "", verified: true))
        #expect(harness.value == "Keep this and then we should check that the feed still works. After that, pick up milk.")
        // Remembered for learning corrected words, like a verified paste.
        #expect(TextDelivery.lastInsertion?.location == 9)
        #expect(TextDelivery.lastInsertion?.text == " and then we should check that the feed still works. After that, pick up milk.")
    }

    /// "Show words instantly": the streaming recognizer's words are typed as they come, a growing word is typed on,
    /// and the pass at the pause rewrites from the first character it changes.
    @Test func firmGuessesAreTypedAtOnce() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.settleAfter; defer { LiveTyper.settleAfter = saved }
        LiveTyper.settleAfter = .seconds(30)   // nothing here may wait for a pause
        harness.set("", cursor: 0)
        let typer = harness.typer()
        typer.hear("Okay so the set", firm: true)
        #expect(await harness.settled("Okay so the set") == "Okay so the set")
        typer.hear("Okay so the settings page", firm: true)
        #expect(await harness.settled("Okay so the settings page") == "Okay so the settings page")
        typer.hear("Okay, so the settings page.", firm: true)
        #expect(await harness.settled("Okay, so the settings page") == "Okay, so the settings page")
        #expect(await typer.finish("Okay, so the settings page.") == .typed(rest: "", verified: true))
        #expect(harness.value == "Okay, so the settings page.")
    }

    /// A recognizer that marks its pauses (Parakeet and Whisper): no guess is typed and no clock stands in for a
    /// pause; a phrase is typed when the pass at its pause has it, a settled word a later pass hears differently
    /// stays, and the stop adds the rest. Not one backspace.
    @Test func aPhraseIsTypedAtItsPauseAndStays() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.settleAfter; defer { LiveTyper.settleAfter = saved }
        LiveTyper.settleAfter = .milliseconds(40)   // a clock that would type a guess long before the checks below
        harness.set("Keep this", cursor: 9)
        let typer = harness.typer(settlesAtPauses: true)
        await harness.say(typer, "And then we should have to do it.", "And then we should have to do it.", "And then we should have to do it.")
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.value == "Keep this")
        typer.hear("And then we should check the feed.", pause: .held)
        #expect(await harness.settled("Keep this and then we should check the feed") == "Keep this and then we should check the feed")
        await harness.say(typer, "And then we should check the feed. After that we're not going to", "And then we should check the feed. After that we're not going to")
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.value == "Keep this and then we should check the feed")
        typer.hear("And then we should check that feed. After that, pick up milk.", pause: .held)
        #expect(await harness.settled("Keep this and then we should check the feed. After that, pick up milk")
                == "Keep this and then we should check the feed. After that, pick up milk")
        let outcome = await typer.finish("And then we should check that feed. After that, pick up milk and the good bread.")
        #expect(outcome == .typed(rest: "", verified: true))
        #expect(harness.value == "Keep this and then we should check the feed. After that, pick up milk and the good bread.")
        #expect(typer.counts?.back == 0 && typer.counts?.backAtStop == 0)
    }

    @Test func aPauseTypesTheNewestGuess() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.settleAfter; defer { LiveTyper.settleAfter = saved }
        LiveTyper.settleAfter = .milliseconds(120)
        harness.set("", cursor: 0)
        let typer = harness.typer()
        await harness.say(typer, "Pick up oat milk on the way home.")
        #expect(await harness.settled("Pick up oat milk on the way home") == "Pick up oat milk on the way home")
        typer.abandon()
    }

    @Test func cancelTakesTheTypedWordsBack() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("Dear team,", cursor: 10)
        let typer = harness.typer()
        await harness.say(typer, "Thanks for the update", "Thanks for the update")
        #expect(await harness.settled("Dear team, thanks for the update") == "Dear team, thanks for the update")
        #expect(await typer.takeBack() == false)
        #expect(await harness.settled("Dear team,") == "Dear team,")
    }

    /// The person edited the field while dictating: nothing of theirs is deleted, the typed words stay as they are,
    /// and the stop is handed only the words after them.
    @Test func textThePersonChangedIsNeverDeleted() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("", cursor: 0)
        let typer = harness.typer()
        await harness.say(typer, "Send the report to the team", "Send the report to the team")
        #expect(await harness.settled("Send the report to the team") == "Send the report to the team")
        try await Task.sleep(for: .milliseconds(200))   // the first words are read back before anything else happens
        // They put the cursor at the start and typed something; no key tap told Mouthy (headless), so the field itself
        // has to: the words before the cursor are no longer the typed ones.
        harness.set("Note: Send the report to the team", cursor: 6)
        await harness.say(typer, "Send a report to the team and copy me", "Send a report to the team and copy me on it")
        try await Task.sleep(for: .milliseconds(700))
        #expect(harness.value == "Note: Send the report to the team" && typer.leftWords)
        #expect(await typer.finish("Send a report to the team and copy me on it.") == .untyped("and copy me on it."))
        #expect(harness.value == "Note: Send the report to the team")
    }

    @Test func aKeyOrClickLeavesTheWordsAndTheStopGetsTheRest() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.quiet; defer { LiveTyper.quiet = saved }
        LiveTyper.quiet = .milliseconds(1)
        harness.set("", cursor: 0)
        let typer = harness.typer()
        await harness.say(typer, "First thought here", "First thought here")
        #expect(await harness.settled("First thought here") == "First thought here")
        try await Task.sleep(for: .milliseconds(200))   // the first words are read back before anything else happens
        // They pressed Return themselves.
        typer.touched()
        harness.set("First thought here\n", cursor: 19)
        await harness.say(typer, "First thought here and a second one", "First thought here and a second one follows")
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.value == "First thought here\n")
        #expect(await typer.finish("First thought here and a second one follows.") == .untyped("and a second one follows."))
        #expect(harness.value == "First thought here\n")
    }

    /// The person added a comma inside the typed words and put the cursor back at the end: the words are not taken
    /// up again, because taking characters back would then reach their comma.
    @Test func wordsThePersonEditedAreNotTakenUpAgain() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.quiet; defer { LiveTyper.quiet = saved }
        LiveTyper.quiet = .milliseconds(1)
        harness.set("", cursor: 0)
        let typer = harness.typer()
        await harness.say(typer, "I went to the store and bought milk", "I went to the store and bought milk")
        #expect(await harness.settled("I went to the store and bought milk") == "I went to the store and bought milk")
        typer.touched()
        harness.set("I went to the store, and bought milk", cursor: 36)
        await harness.say(typer, "I went to the stores and bought milk", "I went to the stores and bought milk")
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.value == "I went to the store, and bought milk" && typer.leftWords)
        #expect(await typer.takeBack())
        #expect(harness.value == "I went to the store, and bought milk")
    }

    /// The person clicked right after their own word that ends like Mouthy's: it is not taken for Mouthy's.
    @Test func thePersonsOwnTextIsNeverTakenUp() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.quiet; defer { LiveTyper.quiet = saved }
        LiveTyper.quiet = .milliseconds(1)
        harness.set("Many thanks, all. ", cursor: 18)
        let typer = harness.typer()
        await harness.say(typer, "Thanks", "Thanks")
        #expect(await harness.settled("Many thanks, all. Thanks") == "Many thanks, all. Thanks")
        try await Task.sleep(for: .milliseconds(200))   // the first words are read back before anything else happens
        typer.touched()
        harness.set("Many thanks, all. Thanks", cursor: 11)
        await harness.say(typer, "Thank you for the update", "Thank you for the update")
        try await Task.sleep(for: .milliseconds(300))
        #expect(harness.value == "Many thanks, all. Thanks" && typer.leftWords)
        #expect(await typer.finish("Thank you for the update.") == .untyped("you for the update."))
        #expect(harness.value == "Many thanks, all. Thanks")
    }

    @Test func aLineBreakIsLeftToThePaste() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("", cursor: 0)
        let typer = harness.typer()
        await harness.say(typer, "First line", "First line")
        #expect(await harness.settled("First line") == "First line")
        let outcome = await typer.finish("First line.\nSecond line.")
        #expect(outcome == .typed(rest: "\nSecond line.", verified: false))
        #expect(await harness.settled("First line.") == "First line.")
    }

    @Test func nothingIsTypedWithoutAFocusedApp() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("Untouched.", cursor: 10)
        let typer = harness.typer()
        TextDelivery.frontmost = { nil }
        await harness.say(typer, "These words wait", "These words wait")
        try await Task.sleep(for: .milliseconds(150))
        #expect(await typer.finish("These words wait.") == .untyped("These words wait."))
        #expect(harness.value == "Untouched." && !typer.typedAnything)
    }

    /// A field that does not take the key presses (its text never changes): live typing stops, nothing counts as
    /// typed, nothing is ever taken back from it, and the stop gets all of the text to paste.
    @Test func aFieldThatIgnoresKeyPressesGetsEverythingAtTheStop() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("Untouched.", cursor: 10)
        let typer = harness.typer()
        LiveTyper.post = { _ in }
        await harness.say(typer, "These words go nowhere", "These words go nowhere")
        try await Task.sleep(for: .milliseconds(900))
        await harness.say(typer, "These words go nowhere at all", "These words went nowhere at all")
        #expect(await typer.finish("These words went nowhere at all.") == .untyped("These words went nowhere at all."))
        #expect(harness.value == "Untouched." && !typer.typedAnything)
    }

    /// A short dictation: nothing was typed before the stop, so the whole text goes out at once into a field that
    /// was never read back. When that field ignores the keys, the words are handed to the paste, never lost.
    @Test func aShortDictationIntoAFieldThatIgnoresKeysIsNotLost() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("Untouched.", cursor: 10)
        let typer = harness.typer()
        LiveTyper.post = { _ in }
        await harness.say(typer, "Short one")
        #expect(await typer.finish("Short one.") == .untyped("Short one."))
        #expect(harness.value == "Untouched.")
    }

    /// Selected text is never typed over: Escape could not bring it back. The stop's paste replaces it, as before.
    @Test func selectedTextIsNotTypedOver() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("Replace this word.", cursor: 8, length: 4)
        let typer = harness.typer()
        await harness.say(typer, "That phrase", "That phrase")
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.value == "Replace this word.")
        #expect(await typer.finish("That phrase.") == .untyped("That phrase."))
        #expect(harness.value == "Replace this word." && !typer.typedAnything)
    }

    /// While ⌘, ⌃ or ⌥ is down nothing is typed (a key press could become a command); the words go in at the stop,
    /// once the key is up.
    @Test func nothingIsTypedWhileAModifierIsHeld() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.modifiersHeld; defer { LiveTyper.modifiersHeld = saved }
        var held = true
        LiveTyper.modifiersHeld = { held }
        harness.set("", cursor: 0)
        let typer = harness.typer()
        await harness.say(typer, "Held back for now", "Held back for now")
        try await Task.sleep(for: .milliseconds(150))
        #expect(harness.value == "" && !typer.typedAnything)
        held = false
        #expect(await typer.finish("Held back for now.") == .typed(rest: "", verified: true))
        #expect(harness.value == "Held back for now.")
    }

    /// A click that leaves the cursor right after the typed words (clicking into the same window): the words are
    /// taken up again, corrected and finished in place.
    @Test func aClickInTheSamePlaceTakesTheWordsUpAgain() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.quiet; defer { LiveTyper.quiet = saved }
        LiveTyper.quiet = .milliseconds(1)
        harness.set("", cursor: 0)
        let typer = harness.typer()
        await harness.say(typer, "Pick up oat milk on the way", "Pick up oat milk on the way")
        #expect(await harness.settled("Pick up oat milk on the way") == "Pick up oat milk on the way")
        try await Task.sleep(for: .milliseconds(200))   // the first words are read back before anything else happens
        typer.touched()
        #expect(typer.leftWords)
        await harness.say(typer, "Pick up oat milk on my way home", "Pick up oat milk on my way home")
        // "the" became "my", two words from the end: only possible because the words are Mouthy's own again.
        #expect(await harness.settled("Pick up oat milk on my way home") == "Pick up oat milk on my way home")
        #expect(!typer.leftWords)
        #expect(await typer.finish("Pick up oat milk on my way home.") == .typed(rest: "", verified: true))
        #expect(harness.value == "Pick up oat milk on my way home.")
    }

    /// The field changed the typed words itself (autocorrect): they are no longer Mouthy's to take back.
    @Test func wordsTheFieldChangedAreLeftAlone() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.set("", cursor: 0)
        let typer = harness.typer()
        await harness.say(typer, "Ask jaxon about it", "Ask jaxon about it")
        #expect(await harness.settled("Ask jaxon about it") == "Ask jaxon about it")
        // The field "corrects" a word: one character more than Mouthy typed.
        harness.set("Ask jackson about it", cursor: 20)
        await harness.say(typer, "Ask jaxon about it today", "Ask jaxon about it today please")
        try await Task.sleep(for: .milliseconds(400))
        // "today" needs no backspace, so it is typed; the next correction would, and the field no longer holds
        // what was typed: nothing is deleted.
        _ = await typer.finish("Ask jaxon about it today, please.")
        #expect(harness.value.hasPrefix("Ask jackson about it"))
    }

    /// "Show words instantly" in the app: the setting reaches the speech engine, and one preview from the streaming
    /// recognizer is typed without waiting for a second or for a pause.
    @Test func instantWordsAreTypedFromOnePreview() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.settleAfter; defer { LiveTyper.settleAfter = saved }
        LiveTyper.settleAfter = .seconds(30)
        harness.takeKeyPresses()
        harness.set("", cursor: 0)
        let speech = FakeSpeech(); speech.previewIsFirm = true
        let (model, _) = stateModel(speech)
        model.preferences.typeAsYouSpeak = true; model.preferences.instantWords = true
        model.begin(captureTarget: true)
        try await waitFor { model.phase == .listening && model.liveTyper != nil }
        #expect(speech.instantWords)
        await harness.preview(speech, "Hi sam thanks")
        #expect(await harness.settled("Hi sam thanks") == "Hi sam thanks")
        #expect(model.typingLive)
        model.cancel()
        try await waitFor { model.phase == .idle }
    }

    /// The card under the notch stays away only while the field is getting all of the words. After a spoken line
    /// break, or while a shortcut's modifier is held, the field is not: the words show on the card again.
    @Test func theCardComesBackWhenTheFieldIsNotGettingTheWords() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.modifiersHeld; defer { LiveTyper.modifiersHeld = saved }
        harness.takeKeyPresses()
        harness.set("", cursor: 0)
        let speech = FakeSpeech(); speech.finalText = "hi sam"
        let (model, _) = stateModel(speech)
        model.preferences.typeAsYouSpeak = true
        model.begin(captureTarget: true)
        try await waitFor { model.phase == .listening && model.liveTyper != nil }
        await harness.preview(speech, "Hi Sam", "Hi Sam", "Hi Sam")
        #expect(await harness.settled("Hi Sam") == "Hi Sam")
        #expect(model.typingLive && model.shownLiveText == "")
        // The text goes on after a line break, which is never typed: after three such guesses the card has it.
        await harness.preview(speech, "Hi Sam new paragraph thanks", "Hi Sam new paragraph thanks for", "Hi Sam new paragraph thanks for the", "Hi Sam new paragraph thanks for the notes")
        #expect(!model.typingLive && model.shownLiveText == "Hi Sam new paragraph thanks for the notes")
        #expect(harness.value == "Hi Sam")
        // Back on one line, the field has all of it again.
        await harness.preview(speech, "Hi Sam thanks", "Hi Sam thanks")
        #expect(model.typingLive)
        // A held modifier: nothing can be typed, so the card shows what is said.
        LiveTyper.modifiersHeld = { true }
        await harness.preview(speech, "Hi Sam thanks for", "Hi Sam thanks for the", "Hi Sam thanks for the notes",
                              "Hi Sam thanks for the notes you", "Hi Sam thanks for the notes you sent")
        #expect(!model.typingLive && model.shownLiveText == "Hi Sam thanks for the notes you sent")
        #expect(harness.value == "Hi Sam")
        LiveTyper.modifiersHeld = { false }
        model.cancel()
        try await waitFor { model.phase == .idle }
    }

    /// A spoken "dash" is not typed as a word: it waits until the word it joins is whole, and the field goes from
    /// "maple" straight to "maple-design".
    @Test func aSpokenDashIsTypedAsTheMarkOnceItsNextWordComes() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.takeKeyPresses()
        harness.set("", cursor: 0)
        let speech = FakeSpeech(); speech.finalText = "name it maple dash design"
        let (model, _) = stateModel(speech)
        model.preferences.typeAsYouSpeak = true
        model.begin(captureTarget: true)
        try await waitFor { model.phase == .listening && model.liveTyper != nil }
        await harness.preview(speech, "Name it maple dash", "Name it maple dash", "Name it maple dash")
        #expect(await harness.settled("Name it maple") == "Name it maple")
        await harness.preview(speech, "Name it maple dash design", "Name it maple dash design")
        #expect(await harness.settled("Name it maple") == "Name it maple")
        await harness.preview(speech, "Name it maple dash design now", "Name it maple dash design now")
        #expect(await harness.settled("Name it maple-design now") == "Name it maple-design now")
        model.cancel()
        try await waitFor { model.phase == .idle }
    }

    /// Return follows only words that are all in the field that has the focus. After the person clicked away
    /// mid-dictation, an Enter does not send what is there.
    @Test func enterDoesNotSendAfterThePersonMovedOn() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        let saved = LiveTyper.quiet; defer { LiveTyper.quiet = saved }
        LiveTyper.quiet = .milliseconds(1)
        harness.takeKeyPresses()
        harness.set("", cursor: 0)
        let speech = FakeSpeech(); speech.splits = ["first thought and more"]
        let (model, log) = stateModel(speech)
        model.preferences.typeAsYouSpeak = true
        model.begin(captureTarget: true)
        try await waitFor { model.phase == .listening && model.liveTyper != nil }
        await harness.preview(speech, "First thought", "First thought")
        #expect(await harness.settled("First thought") == "First thought")
        try await Task.sleep(for: .milliseconds(200))   // the first words are read back before anything else happens
        // They clicked somewhere else in the field and typed: the words are no longer going into the field, so the
        // card shows them again.
        model.liveTyper?.touched()
        harness.set("Mine. First thought", cursor: 5)
        #expect(!model.typingLive && model.shownLiveText == "First thought")
        #expect(model.sendAndContinue())
        // The words after the ones left behind go in by paste (here the test's log), without a Return.
        try await waitFor { !log.texts.isEmpty }
        #expect(log.texts == ["and more"] && log.submits == [false] && log.returns == 0)
        #expect(harness.value == "Mine. First thought")
        model.cancel()
        try await waitFor { model.phase == .idle }
    }

    /// The whole flow through the app model: live words into the field, the finished text at the stop, no paste.
    @Test func aDictationTypesIntoTheFieldAndFinishesWithoutAPaste() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.takeKeyPresses()
        harness.set("", cursor: 0)
        let speech = FakeSpeech(); speech.finalText = "pick up oat milk on the way home"
        // The scorecard is a testing tool: it records only where its file is already there.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: folder.appendingPathComponent("scores.json"))
        let (model, log) = stateModel(speech, directory: folder)
        model.preferences.typeAsYouSpeak = true
        model.begin(captureTarget: true)
        try await waitFor { model.phase == .listening && model.liveTyper != nil }
        await harness.preview(speech, "Pick up oat milk on the way to you.", "Pick up oat milk on the way home.", "Pick up oat milk on the way home.")
        // (Three guesses agree up to "way"; the pause then types the last guess whole.)
        #expect(await harness.settled("Pick up oat milk on the way home") == "Pick up oat milk on the way home")
        // The words are in the field, so the notch card and the island show none.
        #expect(model.typingLive && model.shownLiveText == "" && model.liveText == "Pick up oat milk on the way home.")
        model.stop()
        try await waitFor { model.phase == .idle }
        #expect(harness.value == "Pick up oat milk on the way home")
        #expect(model.status == "Inserted into target." && log.texts.isEmpty && model.liveTyper == nil && !model.typingLive)
        #expect(model.output == "Pick up oat milk on the way home")
        // The dictation's score: numbers only, with what was typed live and how the words got there.
        let score = try #require(model.scores.last)
        #expect(model.scores.count == 1 && score.words == 8 && score.delivery == "Inserted")
        #expect(score.typed == "Pick up oat milk on the way home".count && score.tookBack == 0 && score.tookBackAtStop == 0)
    }

    @Test func escapeTakesTheLiveWordsBack() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.takeKeyPresses()
        harness.set("Keep.", cursor: 5)
        let speech = FakeSpeech()
        let (model, log) = stateModel(speech)
        model.preferences.typeAsYouSpeak = true
        model.begin(captureTarget: true)
        try await waitFor { model.phase == .listening && model.liveTyper != nil }
        await harness.preview(speech, "Never mind this", "Never mind this")
        #expect(await harness.settled("Keep. Never mind this") == "Keep. Never mind this")
        model.cancel()
        try await waitFor { model.phase == .idle }
        #expect(await harness.settled("Keep.") == "Keep.")
        #expect(model.status == "Cancelled. Nothing was inserted." && log.texts.isEmpty)
    }

    /// Enter while dictating: the part typed so far is finished in place and sent, and the next part starts fresh.
    @Test func enterFinishesThePartInPlaceAndSendsIt() async throws {
        let harness = try await Harness(); defer { harness.stop() }
        harness.takeKeyPresses()
        harness.set("", cursor: 0)
        let speech = FakeSpeech(); speech.splits = ["first message"]; speech.finalText = "second message"
        let (model, log) = stateModel(speech)
        model.preferences.typeAsYouSpeak = true
        model.begin(captureTarget: true)
        try await waitFor { model.phase == .listening && model.liveTyper != nil }
        await harness.preview(speech, "First mess", "First mess")
        #expect(await harness.settled("First mess") == "First mess")
        #expect(model.sendAndContinue())
        try await waitFor { log.returns == 1 }
        #expect(harness.value == "First message")
        // The app sent the message and emptied its field.
        harness.set("", cursor: 0)
        try await waitFor { model.status == "Listening…" }
        await harness.preview(speech, "Second message", "Second message")
        #expect(await harness.settled("Second message") == "Second message")
        model.stop()
        try await waitFor { model.phase == .idle }
        #expect(harness.value == "Second message" && log.texts.isEmpty && log.returns == 1)
    }
}
}

/// "Type as I speak" is on but no text field can take the words (here: no app is focused). Nothing is typed, and the
/// stop pastes the whole text as it does with the setting off. No key press leaves this test. (Skipped beside the
/// headless delivery tests, which own the same seams.)
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_DELIVERY"] != "1"))
func typeAsISpeakWithoutATextFieldPastesEverythingAtTheStop() async throws {
    let front = TextDelivery.frontmost, post = LiveTyper.post
    defer { TextDelivery.frontmost = front; LiveTyper.post = post }
    TextDelivery.frontmost = { nil }
    LiveTyper.post = { _ in Issue.record("a key press left the test") }
    let speech = FakeSpeech(); speech.finalText = "all of it at the stop"
    let (model, log) = stateModel(speech)
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening }
    // Off (the default): nothing listens for live words.
    #expect(model.liveTyper == nil)
    model.cancel()
    try await waitFor { model.phase == .idle }

    model.preferences.typeAsYouSpeak = true
    model.begin(captureTarget: true)
    try await waitFor { model.phase == .listening && model.liveTyper != nil }
    speech.onPreview?("All of it")
    try await Task.sleep(for: .milliseconds(60))
    speech.onPreview?("All of it at the")
    try await Task.sleep(for: .milliseconds(60))
    // No field takes the words, so the notch card and the island are how the person sees them.
    #expect(!model.typingLive && model.shownLiveText == "All of it at the")
    model.stop()
    try await waitFor { model.phase == .idle }
    #expect(log.texts == ["All of it at the stop"] && model.status == "Pasted into Target." && model.liveTyper == nil)
}

/// Pressing the dictation shortcut to stop is not the person typing in the field; any other key is.
@MainActor @Test func theDictationShortcutIsNotTakenForTyping() {
    let hotkey = HotkeyService(live: false)
    hotkey.trusted = { true }
    _ = hotkey.register(preset: 0)   // ⌃⌥Space
    #expect(hotkey.isOwnShortcut(49, flags: [.maskControl, .maskAlternate]))
    #expect(hotkey.isOwnShortcut(49, flags: [.maskControl, .maskAlternate, .maskNonCoalesced]))
    #expect(!hotkey.isOwnShortcut(49, flags: []))                                  // a space typed in the field
    #expect(!hotkey.isOwnShortcut(0, flags: [.maskControl, .maskAlternate]))
    _ = hotkey.register(preset: 3, customKeyCode: 2, customModifiers: 256)           // ⌘D
    #expect(hotkey.isOwnShortcut(2, flags: .maskCommand) && !hotkey.isOwnShortcut(2, flags: [.maskCommand, .maskShift]))
    // The double tap and Hold Fn press no key.
    _ = hotkey.register(preset: 4)
    #expect(!hotkey.isOwnShortcut(49, flags: [.maskControl, .maskAlternate]))
    // Paste last (⌃⌘V), the notch hub (⌃⌥N) and a mode's shortcut also stop or leave the field alone.
    #expect(hotkey.isOwnShortcut(9, flags: [.maskControl, .maskCommand]) && hotkey.isOwnShortcut(45, flags: [.maskControl, .maskAlternate]))
    #expect(!hotkey.isOwnShortcut(9, flags: .maskCommand))                            // the person's own ⌘V
    _ = hotkey.register(preset: 4, modeShortcuts: [nil, ModeShortcut(keyCode: 14, modifiers: 256 | 2048, label: "⌥⌘E")])
    #expect(hotkey.isOwnShortcut(14, flags: [.maskCommand, .maskAlternate]) && !hotkey.isOwnShortcut(14, flags: .maskCommand))
}
