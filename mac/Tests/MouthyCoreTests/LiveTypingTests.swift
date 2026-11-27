import Foundation
import Testing
@testable import MouthyCore

/// Plays edits into a string the way a field takes key presses: backspaces before the cursor, then the text.
private func apply(_ edits: [LiveTyping.Edit], to field: inout String) {
    for edit in edits {
        switch edit {
        case .delete(let count): field.removeLast(count)
        case .type(let text): field += text
        }
    }
}

/// A guess heard three times, and then a pause: all of it is in the field. Words typed one after another are one
/// edit here, whichever of the guesses and the pause typed them.
private func say(_ text: String, to typing: inout LiveTyping) -> [LiveTyping.Edit] {
    (typing.hear(text) + typing.hear(text) + typing.hear(text) + typing.settle()).reduce(into: []) { edits, edit in
        if case .type(let more) = edit, case .type(let text)? = edits.last { edits[edits.count - 1] = .type(text + more) } else { edits.append(edit) }
    }
}

@Test func liveTypingTypesWordsOnceGuessesAgreeOnThem() {
    var typing = LiveTyping(), field = ""
    // The newest words of a guess are often invented: nothing of the first guess is typed.
    apply(typing.hear("Okay so then."), to: &field)
    #expect(field == "")
    // Two guesses agree on two words: that is not enough yet.
    apply(typing.hear("Okay so the next thing is that the first one is"), to: &field)
    #expect(field == "")
    // Three guesses agree on "Okay so".
    apply(typing.hear("Okay so the next thing I want to do."), to: &field)
    #expect(field == "Okay so")
    // Three guesses agree up to "thing".
    apply(typing.hear("Okay so the next thing I want to do is"), to: &field)
    #expect(field == "Okay so the next thing")
    // The same guess again and again: everything but its newest word, which may still change with what comes
    // after it.
    apply(typing.hear("Okay so the next thing I want to do is"), to: &field)
    #expect(field == "Okay so the next thing I want to do")
    #expect(typing.hear("Okay so the next thing I want to do is").isEmpty)
    // A pause: the rest of it.
    apply(typing.settle(), to: &field)
    #expect(field == "Okay so the next thing I want to do is")
}

@Test func liveTypingNeverTypesAnEndingTheRecognizerMadeUp() {
    var typing = LiveTyping(), field = ""
    for guess in ["I will", "I will still", "I will still need", "I will still need", "I will still need"] { apply(typing.hear(guess), to: &field) }
    #expect(field == "I will still")
    // The audio ends mid-word and the recognizer finishes the sentence itself, in two guesses running. None of the
    // ending is typed.
    apply(typing.hear("I will still need to be able to do it."), to: &field)
    apply(typing.hear("I will still need to be able to do that."), to: &field)
    #expect(field == "I will still need")
    // The next guess heard the pause: nothing made up was typed, so nothing has to be taken back.
    #expect(typing.hear("I will still need to.").isEmpty)
    #expect(typing.hear("I will still need to.").isEmpty)
    apply(typing.settle(), to: &field)
    #expect(field == "I will still need to")
}

@Test func liveTypingTypesAFirmGuessAtOnce() {
    var typing = LiveTyping(), field = ""
    // The streaming recognizer never takes a word back: every guess is typed whole, and a word that grows is only
    // typed on, never deleted.
    apply(typing.hear("Okay so the set", firm: true), to: &field)
    #expect(field == "Okay so the set")
    let edits = typing.hear("Okay so the settings page", firm: true)
    #expect(edits == [.type("tings page")])
    apply(edits, to: &field)
    // The pass at the pause rewrites from the first character it changes, and its closing mark waits for more words.
    apply(typing.hear("Okay, so the settings page.", firm: true), to: &field)
    #expect(field == "Okay, so the settings page")
    apply(typing.hear("Okay, so the settings page. into", firm: true), to: &field)
    #expect(field == "Okay, so the settings page. into")
    // A guess that is not firm goes back to waiting for agreement, without taking typed words away.
    apply(typing.hear("Okay, so the settings page. Into its own window"), to: &field)
    #expect(field == "Okay, so the settings page. Into")
}

@Test func liveTypingTypesTheNewestGuessWhenThePersonPauses() {
    var typing = LiveTyping(), field = ""
    apply(typing.hear("Pick up oat milk on the way to you."), to: &field)
    apply(typing.hear("Pick up oat milk on the way home."), to: &field)
    #expect(field == "")
    // No newer guess came: the last one stands, without the period a pause always gets.
    apply(typing.settle(), to: &field)
    #expect(field == "Pick up oat milk on the way home")
    // The sentence went on, so the period was never there to take back; the new words wait for a third guess
    // that has them.
    #expect(typing.hear("Pick up oat milk on the way home, and the good bread.").isEmpty)
    #expect(typing.hear("Pick up oat milk on the way home, and the good bread for dinner.").isEmpty)
    apply(typing.hear("Pick up oat milk on the way home, and the good bread for dinner tonight"), to: &field)
    #expect(field == "Pick up oat milk on the way home, and the good bread")
}

/// With a recognizer that says when it heard a pause, a phrase is typed at each pause as the pass over everything
/// said has it, and then stays: no guess in between is typed, nothing is ever taken back, and the stop only adds
/// what was said after the last pause. (Typed from the guesses, a person's real speech left words in the field
/// that the recognizer had made up or misheard, and the stop took back half of a long dictation to correct the
/// first of them: recorded readings, 2026-11-26.)
@Test func liveTypingTypesAPhraseAtEachPauseAndNeverTakesItBack() {
    var typing = LiveTyping(), field = "", deleted = 0
    typing.settlesAtPauses = true
    typing.attach(before: "", after: "")
    func play(_ edits: [LiveTyping.Edit]) {
        for edit in edits { if case .delete(let count) = edit { deleted += count } }
        apply(edits, to: &field)
    }
    // Guesses while the person speaks, however often they agree: nothing is typed, made up or not.
    for guess in ["But the", "But the nation itself", "But the nation itself and then we're not going to", "But the nation itself and then we're not going to",
                  "But the nation itself and then we're not going to"] { play(typing.hear(guess)) }
    #expect(field == "")
    // The pass at the pause: the phrase, without the period every pause gets.
    play(typing.hear("But the nation itself.", pause: .held))
    #expect(field == "But the nation itself")
    // The sentence went on. The next pause brings the period with the words after it, and its comma.
    play(typing.hear("But the nation itself. And whatever may be"))
    #expect(field == "But the nation itself")
    play(typing.hear("But the nation itself. And whatever may be its symbols, its insignia.", pause: .held))
    #expect(field == "But the nation itself. And whatever may be its symbols, its insignia")
    // A later pass hears a settled word differently: it stays, and the new words follow it.
    play(typing.hear("But the nation itself. And whatever may be its symbol, its insignia, he reads chiefly in the flag.", pause: .held))
    #expect(field == "But the nation itself. And whatever may be its symbols, its insignia, he reads chiefly in the flag")
    // A later pass lost the first sentence (a recorded one did): the field keeps what it has, and nothing after it
    // is typed twice.
    play(typing.hear("And whatever may be its symbols, its insignia, he reads chiefly in the flag the government.", pause: .held))
    #expect(field == "But the nation itself. And whatever may be its symbols, its insignia, he reads chiefly in the flag the government")
    // The same pass again changes nothing.
    #expect(typing.hear("And whatever may be its symbols, its insignia, he reads chiefly in the flag the government.", pause: .held).isEmpty)
    // The stop adds what was said since the last pause, and the closing mark.
    let finished = typing.finish("But the nation itself. And whatever may be its symbol, its insignia, he reads chiefly in the flag, the government, the principles.")
    play(finished.edits)
    #expect(field == "But the nation itself. And whatever may be its symbols, its insignia, he reads chiefly in the flag the government, the principles.")
    #expect(deleted == 0 && field == typing.typed)

    // The first word or two wait for more: the pass that heard them had hardly any sound to go by.
    var start = LiveTyping(), startField = ""
    start.settlesAtPauses = true
    start.attach(before: "", after: "")
    #expect(start.hear("All right.", pause: .held).isEmpty)
    apply(start.hear("Alright, yeah, so basically.", pause: .held), to: &startField)
    #expect(startField == "Alright, yeah, so basically")
    // Two settled words that the next pass writes as one are that word: nothing is typed twice.
    var joined = LiveTyping(), joinedField = ""
    joined.settlesAtPauses = true
    joined.attach(before: "", after: "")
    apply(joined.hear("Well that is all right.", pause: .held), to: &joinedField)
    apply(joined.hear("Well that is alright, yeah, so basically.", pause: .held), to: &joinedField)
    #expect(joinedField == "Well that is all right yeah, so basically")
    // The person talked on after a short pause: the pass heard its last words with nothing after them and made an
    // ending up (recorded). Its last three words wait for the next pause.
    var on = LiveTyping(), onField = ""
    on.settlesAtPauses = true
    on.attach(before: "", after: "")
    apply(on.hear("Certain things we definitely can do, and we can do.", pause: .talkedOn), to: &onField)
    #expect(onField == "Certain things we definitely can do, and")
    apply(on.hear("Certain things we definitely can do, and we need to teach it to be able to.", pause: .talkedOn), to: &onField)
    #expect(onField == "Certain things we definitely can do, and we need to teach it to")
    // A pause that holds settles everything it heard.
    apply(on.hear("Certain things we definitely can do, and we need to teach it to fully understand.", pause: .held), to: &onField)
    #expect(onField == "Certain things we definitely can do, and we need to teach it to fully understand")
    // And the stop needs no second hearing.
    var once = LiveTyping()
    once.settlesAtPauses = true
    once.attach(before: "", after: "")
    #expect(once.hear("Then we're not going.", pause: .talkedOn).isEmpty)
    #expect(once.finish("Then, the long nose.").edits == [.type("Then, the long nose.")])
    // Review round 1. A pass that hears a settled word differently while the person talks on: the words after
    // the settled ones follow, and none of them is typed twice.
    var twice = LiveTyping(), twiceField = ""
    twice.settlesAtPauses = true
    twice.attach(before: "", after: "")
    apply(twice.hear("We should send the report today.", pause: .held), to: &twiceField)
    apply(twice.hear("We should send a report today and then", pause: .talkedOn), to: &twiceField)
    #expect(twiceField == "We should send the report today")
    apply(twice.hear("We should send a report today and then call Dana.", pause: .held), to: &twiceField)
    #expect(twiceField == "We should send the report today and then call Dana")
    // A settled last word that the finished text goes on past behind a mark gets the rest of it.
    var maple = LiveTyping(), mapleField = ""
    maple.settlesAtPauses = true
    maple.attach(before: "", after: "")
    apply(maple.hear("So the maple.", pause: .held), to: &mapleField)
    apply(maple.finish("So, the maple-design team.").edits, to: &mapleField)
    #expect(mapleField == "So the maple-design team.")
    // "Scratch that" took settled words back: the stop corrects the field from the first of them.
    var scratch = LiveTyping(), scratchField = ""
    scratch.settlesAtPauses = true
    scratch.attach(before: "", after: "")
    apply(scratch.hear("Call the landlord. Buy milk and eggs.", pause: .held), to: &scratchField)
    apply(scratch.finish("Call the landlord. Buy bread.").edits, to: &scratchField)
    #expect(scratchField == "Call the landlord. Buy bread.")
    // Review round 2: words heard differently side by side are no removed words. The stop adds the rest and
    // takes nothing back.
    var respelt = LiveTyping(), respeltField = ""
    respelt.settlesAtPauses = true
    respelt.attach(before: "", after: "")
    apply(respelt.hear("Okay so all right we need to move the settings page to their house and then check the feed.", pause: .held), to: &respeltField)
    let respeltStop = respelt.finish("Okay so alright we need to move the settings page too there house and then check the feed and the bread.").edits
    #expect(respeltStop == [.type(" and the bread.")])
    // Review round 3: a pair the text joins, next to one dropped word, is no removed stretch either.
    var pair = LiveTyping(), pairField = ""
    pair.settlesAtPauses = true
    pair.attach(before: "", after: "")
    apply(pair.hear("That is all right so we go.", pause: .held), to: &pairField)
    #expect(pair.finish("That is alright, we go.").edits == [.type(".")])
    // A stretch that runs to the end keeps the finished text's ending: its period, and the space before the text
    // after the cursor.
    var ending = LiveTyping(), endingField = ""
    ending.settlesAtPauses = true
    ending.attach(before: "", after: "Thanks")
    apply(ending.hear("We should check the feed and we can do.", pause: .held), to: &endingField)
    apply(ending.finish("We should check the feed.").edits, to: &endingField)
    #expect(endingField == "We should check the feed. ")
    // A long dictation's stop with a removed stretch near its end is quick, and corrects only that stretch.
    var long = LiveTyping(), longText = ""
    long.settlesAtPauses = true
    long.attach(before: "", after: "")
    let sentences = (0..<200).map { "Item number \($0) goes on the list." }
    apply(long.hear(sentences.joined(separator: " ") + " Buy milk and eggs.", pause: .held), to: &longText)
    let clock = ContinuousClock(), began = clock.now
    let longStop = long.finish(sentences.joined(separator: " ") + " Buy bread.").edits
    #expect(clock.now - began < .seconds(1), "\(clock.now - began)")
    #expect(longStop == [.delete("milk and eggs".count), .type("bread.")])
    // Made-up words far back stay: taking them out would retype everything after them.
    var far = LiveTyping(), farField = ""
    far.settlesAtPauses = true
    far.attach(before: "", after: "")
    apply(far.hear("The history, and the city which belong to the nation. " + sentences.prefix(20).joined(separator: " "), pause: .held), to: &farField)
    let farStop = far.finish("The history, which belong to the nation. " + sentences.prefix(20).joined(separator: " ") + " Done.").edits
    #expect(farStop == [.type(". Done.")])
    // Typed in front of text: the space before it comes at the end, and the marks between phrases stay.
    var front = LiveTyping(), frontField = ""
    front.settlesAtPauses = true
    front.attach(before: "", after: "Thanks")
    apply(front.hear("Pick up oat milk.", pause: .held), to: &frontField)
    #expect(frontField == "Pick up oat milk")
    apply(front.hear("Pick up oat milk. And the bread.", pause: .held), to: &frontField)
    #expect(frontField == "Pick up oat milk. And the bread")
    apply(front.finish("Pick up oat milk. And the bread.").edits, to: &frontField)
    #expect(frontField == "Pick up oat milk. And the bread. ")
    // A stop with nothing new types the mark that was held back, and no more.
    var short = LiveTyping(), shortField = ""
    short.settlesAtPauses = true
    short.attach(before: "", after: "")
    apply(short.hear("Pick up oat milk on the way home.", pause: .held), to: &shortField)
    #expect(shortField == "Pick up oat milk on the way home")
    #expect(short.finish("Pick up oat milk on the way home.").edits == [.type(".")])
    // A stop before any pause types everything at once.
    var quick = LiveTyping()
    quick.settlesAtPauses = true
    quick.attach(before: "", after: "")
    #expect((quick.hear("Call me") + quick.hear("Call me at") + quick.hear("Call me at nine")).isEmpty)
    #expect(quick.finish("Call me at nine.").edits == [.type("Call me at nine.")])
    // Words that were left (the person clicked) and taken up again stay as they are too.
    var left = LiveTyping(), leftField = ""
    left.settlesAtPauses = true
    left.attach(before: "", after: "")
    apply(left.hear("Move the tomatoes.", pause: .held), to: &leftField)
    left.leave()
    #expect(left.remainder(of: "Move the tomatoes to the back bed.") == "to the back bed.")
    left.reclaim()
    #expect(left.hear("Move the tomato to the back bed.", pause: .held) == [.type(" to the back bed")])
}

/// A word that is in the field never changes while the person is speaking: what a later guess writes differently
/// stays as typed, the words after it follow, and the stop corrects the field once.
@Test func liveTypingNeverTakesATypedWordBackWhileSpeaking() {
    var typing = LiveTyping(), field = ""
    apply(say("the update feed still works after that", to: &typing), to: &field)
    #expect(field == "the update feed still works after that")
    // A comma arrives behind typed words, and two new words.
    let edits = say("the update feed still works, after that pick up", to: &typing)
    #expect(edits == [.type(" pick up")])
    apply(edits, to: &field)
    // A typed word is heard differently, and more words come: it stays, they follow.
    let more = say("the update feet still works, after that pick up the bread", to: &typing)
    #expect(more == [.type(" the bread")])
    apply(more, to: &field)
    #expect(field == "the update feed still works after that pick up the bread")
    // The stop: from the changed word on, once.
    apply(typing.finish("the update feet still works, after that pick up the bread.").edits, to: &field)
    #expect(field == "the update feet still works, after that pick up the bread.")
}

/// Only the newest word or two may still be typed again, when the guess writes just them differently.
@Test func liveTypingLetsTheNewestWordFinishItself() {
    var typing = LiveTyping(), field = ""
    apply(say("All", to: &typing), to: &field)
    let edits = say("Alright yeah so", to: &typing)
    #expect(edits == [.delete(1), .type("right yeah so")])
    apply(edits, to: &field)
    #expect(field == "Alright yeah so")
    // A word that only grows is typed on.
    #expect(say("Alright yeah so the set", to: &typing) == [.type(" the set")])
    #expect(say("Alright yeah so the settings page", to: &typing) == [.type("tings page")])
    // A different word there is typed again too: the field says what the guess says.
    #expect(say("Alright yeah so the settings window is", to: &typing) == [.delete(4), .type("window is")])
    // Never from a guess that is shown only up to a word before the last typed one: nothing goes away to come back.
    var held = LiveTyping(), heldField = ""
    apply(say("Pick up oat milk on the way", to: &held), to: &heldField)
    #expect((held.hear("Pick up oat milk on my way") + held.hear("Pick up oat milk on my way") + held.hear("Pick up oat milk on my way")).isEmpty)
    #expect(held.settle() == [.delete(7), .type("my way")])
    // A guess shown as far as the last typed word types them again as soon as three guesses agree, once.
    var reach = LiveTyping(), reachField = ""
    apply(say("Pick up oat milk on the way", to: &reach), to: &reachField)
    #expect((reach.hear("Pick up oat milk on my way home") + reach.hear("Pick up oat milk on my way home")).isEmpty)
    #expect(reach.hear("Pick up oat milk on my way home") == [.delete(7), .type("my way")])
    #expect(reach.settle() == [.type(" home")])
    // So are the newest two.
    #expect(say("Alright yeah so the settings door is open now", to: &typing) == [.delete(9), .type("door is open now")])
    // Four words back is not the newest any more: it stays for the stop.
    #expect(say("Alright yeah so the settings floor is open now and", to: &typing) == [.type(" and")])
}

/// A guess that no longer has the newest typed words must never make real words disappear behind them (review,
/// 2026-11-26: lined up by count, "one", "yeah" and "go home" were left out of the field, and out of the text when
/// the person clicked before the stop).
@Test func liveTypingNeverSkipsAWordBehindTypedOnesTheGuessChanged() {
    func field(_ first: String, pause: Bool, then guess: String) -> String {
        var typing = LiveTyping(), field = ""
        apply(typing.hear(first) + typing.hear(first) + typing.hear(first) + (pause ? typing.settle() : []), to: &field)
        apply(typing.hear(guess) + typing.hear(guess) + typing.hear(guess) + typing.settle(), to: &field)
        return field
    }
    // A repeated word the next guess has one fewer of.
    #expect(field("Testing testing testing testing one two", pause: false, then: "Testing testing testing one two three four")
            == "Testing testing testing one two three four")
    // Two typed words come back as one.
    #expect(field("All right yeah", pause: false, then: "Alright yeah so we go now") == "Alright yeah so we go now")
    // An ending the recognizer made up at a pause.
    #expect(field("I will still need to be able.", pause: true, then: "I will still need to go home now") == "I will still need to go home now")
    // A word heard in front of the newest typed ones.
    #expect(field("I want to", pause: true, then: "I really want two go") == "I really want two go")
    // Review round 2: words written differently are not made up, and nothing goes in twice. Not while the guess is
    // shown only up to a word before the one both have,
    var spelled = LiveTyping(), house = ""
    apply(say("We went too there house", to: &spelled), to: &house)
    let shown = spelled.hear("We went to their house today") + spelled.hear("We went to their house today") + spelled.hear("We went to their house today")
    #expect(shown.isEmpty)
    apply(spelled.settle(), to: &house)
    #expect(house == "We went too there house today")
    // and not in what the stop pastes after words that were left.
    func rest(left: String, finished: String) -> String {
        var typing = LiveTyping()
        _ = say(left, to: &typing)
        typing.leave()
        return typing.remainder(of: finished)
    }
    #expect(rest(left: "I think there going to", finished: "I think they're going too far.") == "far.")
    #expect(rest(left: "its time to go to bobs", finished: "It's time to go to Bob's place.") == "place.")
    // A field that holds nothing the guess says (words heard in a noise at a pause) still gets what is said next.
    var noise = LiveTyping(), after = ""
    apply(say("Thank you for watching", to: &noise), to: &after)
    apply(say("Okay so the plan is to rest", to: &noise), to: &after)
    #expect(after == "Thank you for watching Okay so the plan is to rest")
    // Typed in front of a word, a period that is not typed does not leave its capital behind.
    var front = LiveTyping(), middle = ""
    front.attach(before: "", after: "Thanks, all.")
    apply(say("We rest", to: &front), to: &middle)
    apply(say("We rest. Then we go", to: &front), to: &middle)
    #expect(middle == "We rest then we go ")
    // Review round 3: a made-up ending with a word in it that is really said a little later ("to") is not pinned to
    // that word. The real words before it are typed too,
    var pinned = LiveTyping(), rest2 = ""
    apply(say("We should be able to do it", to: &pinned), to: &rest2)
    apply(say("We should go home to rest now", to: &pinned), to: &rest2)
    #expect(rest2 == "We should be able to do it go home to rest now")
    pinned.leave()
    #expect(pinned.remainder(of: "We should go home to rest now.") == "")
    // and a correct typed word is never taken back for a guess that still has it but is not shown that far yet.
    var want = LiveTyping(), wanted = ""
    apply(say("I want to", to: &want), to: &wanted)
    #expect((want.hear("I want you to") + want.hear("I want you to") + want.hear("I want you to")).isEmpty)
    #expect(want.settle() == [.delete(2), .type("you to")])
    // A long dictation with a word that stayed wrong near its start is still lined up quickly, guess after guess.
    var lengthy = LiveTyping(), longField = ""
    let many = (0..<400).map { "\(["apple", "bring", "cold", "door", "every", "find", "green", "house", "into", "just", "keep", "long", "more"][$0 % 13])\($0 % 37)" }
    apply(say(many.joined(separator: " "), to: &lengthy), to: &longField)
    var changed = many; changed[2] = "other"
    let clock = ContinuousClock(), started = clock.now
    for extra in 1...20 {
        apply(lengthy.hear((changed + (0..<extra).map { "more\($0)" }).joined(separator: " ")), to: &longField)
    }
    print("live typing: 20 guesses of 400 words with the third one changed lined up in \(clock.now - started)")
    #expect(longField.hasSuffix("more17") && clock.now - started < .seconds(3), "\(clock.now - started)")
    // A guess much shorter than that field (a recorded one lost its newest 25 words for a moment) changes nothing,
    // and is lined up without reading past its end: with 26 words fewer than the field or more this crashed the
    // app, and with 25 it counted wrong.
    let atLength = longField
    for count in [60, 330, 370, 375, 393, 395, 399] {
        apply(lengthy.hear(changed.prefix(count).joined(separator: " ")), to: &longField)
        apply(lengthy.settle(), to: &longField)
        #expect(longField == atLength, "\(count): …\(longField.suffix(60))")
        #expect(LiveTyping.covered(many, in: Array(changed.prefix(count))) == count, "\(count): \(LiveTyping.covered(many, in: Array(changed.prefix(count))))")
    }
    // More made-up words than may be typed again: they stay until the stop, and every real word is there behind them.
    var typing = LiveTyping(), long = ""
    apply(say("We should be able to do it", to: &typing), to: &long)
    apply(say("We should go home now and rest", to: &typing), to: &long)
    #expect(long == "We should be able to do it go home now and rest")
    apply(typing.finish("We should go home now and rest.").edits, to: &long)
    #expect(long == "We should go home now and rest.")
}

/// Random dictations where guesses end in words the recognizer made up (some typed at a pause), lose their newest
/// words again, and repeat words: whenever the person leaves the field, what is in it plus what the stop pastes
/// holds every word that was said, in order, and a dictation that is finished in place ends as the finished text.
@Test func liveTypingLosesNoWordWhenGuessesTakeTheirEndingsBack() {
    struct Random {
        var state: UInt64
        mutating func next(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(count))
        }
    }
    let vocabulary = ["we", "go", "home", "now", "and", "then", "testing", "testing", "one", "two", "the", "plan", "is", "to", "rest", "so"]
    let invented = ["zebra", "quartz", "violin", "marble"]
    func holds(_ got: [String], _ said: [String]) -> Bool {
        var at = 0
        for word in said {
            guard let found = got[at...].firstIndex(of: word) else { return false }
            at = found + 1
        }
        return true
    }
    var random = Random(state: 3), lost: [String] = [], unfinished: [String] = [], worstBack = 0
    for round in 0..<3000 {
        let said = (0..<(6 + random.next(14))).map { _ in vocabulary[random.next(vocabulary.count)] }
        let finished = said.joined(separator: " ")
        var typing = LiveTyping(), field = ""
        let leaveAt = round % 2 == 0 ? 2 + random.next(said.count) : Int.max
        var count = 1 + random.next(3), left = false
        while count <= said.count, !left {
            var words = Array(said[..<count])
            // The newest words are made up, or the guess stops short of the last one.
            for _ in 0..<[0, 0, 1, 2, 4][random.next(5)] { words.append(invented[random.next(invented.count)]) }
            if random.next(6) == 0, words.count > 1 { words.removeLast() }
            let guess = words.joined(separator: " ")
            var back = 0
            for edit in typing.hear(guess) + typing.hear(guess) + typing.hear(guess) + (random.next(3) == 0 ? typing.settle() : []) {
                if case .delete(let count) = edit { back += count }
                apply([edit], to: &field)
            }
            worstBack = max(worstBack, back)
            // While the person speaks: the real words in the field are the ones said so far, each once, in order.
            let real = field.split(separator: " ").map(String.init).filter { !invented.contains($0) }
            if real != Array(said.prefix(real.count)) { lost.append("typing: \(field) | \(finished)") }
            if count >= leaveAt {
                typing.leave(); left = true
                let rest = typing.remainder(of: finished)
                // (One made-up word at the end of the field is taken for the word said there, heard differently:
                // `lineUp`. That one word is then missing.)
                let tail = field.split(separator: " ").suffix(2).map { invented.contains(String($0)) }
                if tail != [false, true], !holds((field + " " + rest).split(separator: " ").map(String.init), said) { lost.append("\(field) + \(rest) | \(finished)") }
            }
            count += 1 + random.next(3)
        }
        if !left {
            apply(typing.finish(finished).edits, to: &field)
            if field != finished { unfinished.append("\(field) | \(finished)") }
        }
    }
    #expect(lost.isEmpty, "\(lost.count) lost, first: \(lost.prefix(4).joined(separator: " ;; "))")
    #expect(unfinished.isEmpty, "\(unfinished.count) not finished, first: \(unfinished.prefix(3).joined(separator: " ;; "))")
    // Only the newest two words are ever typed again while speaking.
    #expect(worstBack <= 2 * 7 + 1, "\(worstBack)")
}

@Test func liveTypingNeverTypesFewerWordsBecauseAGuessDisagreesEarly() {
    var typing = LiveTyping(), field = ""
    apply(say("move the settings page into its own window", to: &typing), to: &field)
    // A guess that changes the second word takes nothing in the field back, however often it says so, and the
    // words after the typed ones still come.
    #expect(typing.hear("move those settings page into its own window and then").isEmpty)
    #expect(typing.hear("move those settings page into its own window and then").isEmpty)
    #expect(typing.hear("move those settings page into its own window and then") == [.type(" and")])
    #expect(typing.settle() == [.type(" then")])
    field += " and then"
    #expect(field == "move the settings page into its own window and then")
}

@Test func liveTypingLeavesTypedWordsAloneWhenOneGuessHearsThemDifferently() {
    var typing = LiveTyping(), field = ""
    let said = "the one over there and like four rows"
    apply(say(said, to: &typing), to: &field)
    #expect(field == said)
    // One guess drops a word, the next has it again: nothing is taken back, and the new words still come.
    #expect(typing.hear("the one over there like four rows for").isEmpty)
    #expect(typing.hear("the one over there and like four rows for").isEmpty)
    #expect(typing.hear("the one over there and like four rows for the").isEmpty)
    apply(typing.hear("the one over there and like four rows for the beans"), to: &field)
    apply(typing.hear("the one over there and like four rows for the beans"), to: &field)
    #expect(field == "the one over there and like four rows for the")
    // A pause: the newer words of the guess that stands are typed. What it changes in the field waits for the stop.
    _ = typing.hear("the one over there and like for rows for the beans")
    apply(typing.settle(), to: &field)
    #expect(field == "the one over there and like four rows for the beans")
}

@Test func liveTypingFinishBringsTheFieldToTheFinalText() {
    var typing = LiveTyping(), field = ""
    apply(typing.hear("I think that covers everything for to") + typing.hear("I think that covers everything for to") + typing.hear("I think that covers everything for to"), to: &field)
    let finished = typing.finish("I think that covers everything for today.")
    apply(finished.edits, to: &field)
    #expect(field == "I think that covers everything for today.")
    #expect(finished.rest == "")
    #expect(typing.typed == field)
}

@Test func liveTypingFitsTheTextAroundTheCursor() {
    var typing = LiveTyping(), field = ""
    typing.attach(before: "Keep this", after: "")
    apply(say("And then we check", to: &typing), to: &field)
    #expect(field == " and then we check")
    apply(typing.finish("And then we check it.").edits, to: &field)
    #expect(field == " and then we check it.")
}

@Test func liveTypingNeverTypesALineBreakOrATab() {
    var typing = LiveTyping(), field = ""
    // A line break typed as a key press is a Return: it would send a chat message.
    apply(say("First line\nsecond line", to: &typing), to: &field)
    #expect(field == "First line")
    let finished = typing.finish("First line.\nSecond line.\tDone.")
    apply(finished.edits, to: &field)
    #expect(field == "First line.")
    #expect(finished.rest == "\nSecond line.\tDone.")
}

@Test func liveTypingLeavesCharactersABackspaceMayNotRemoveToThePaste() {
    var typing = LiveTyping(), field = ""
    let finished = typing.finish("Looks good 👍🏽 thanks")
    apply(finished.edits, to: &field)
    #expect(field == "Looks good ")
    #expect(finished.rest == "👍🏽 thanks")
}

/// Typed words stay as they were typed: a comma or a capital that arrives for them later is left out, a word that
/// changed waits for the stop, and the stop takes nothing back for a mark far behind.
@Test func liveTypingKeepsWordsAsTheyWereTyped() {
    var typing = LiveTyping(), field = ""
    func hear(_ text: String) -> [LiveTyping.Edit] { say(text, to: &typing) }
    apply(hear("We fetched it and then we should check the update"), to: &field)
    #expect(field == "We fetched it and then we should check the update")
    // The pass after the next pause puts a comma in front of the clause: nothing is taken back for it.
    let late = hear("We fetched it, and then we should check the update feed")
    #expect(late == [.type(" feed")])
    apply(late, to: &field)
    // A mark on the newest words is written at once.
    apply(hear("We fetched it, and then we should check the update feed, after that we rest"), to: &field)
    #expect(field == "We fetched it and then we should check the update feed, after that we rest")
    // A word that changed stays as typed while the person speaks.
    #expect(hear("We fetched it, and then we could check the update feed, after that we rest").isEmpty)
    // The stop corrects it where it is, takes back nothing for the comma 60 characters ago, and writes the end.
    let finished = typing.finish("We fetched it, and then we could check the update feed, after that we rest.")
    #expect(finished.edits.first == .delete("should check the update feed, after that we rest".count) && finished.rest.isEmpty)
    apply(finished.edits, to: &field)
    #expect(field == "We fetched it and then we could check the update feed, after that we rest." && typing.typed == field)

    // A period that comes late does not leave its capital behind alone.
    var other = LiveTyping(), second = ""
    apply(say("We fetched the update and we rest then everything", to: &other), to: &second)
    apply(say("We fetched the update and we rest. Then everything goes", to: &other), to: &second)
    #expect(second == "We fetched the update and we rest then everything goes")
    // Nor when the capital word has a mark of its own, and a capital that was typed stays when its period turns
    // into a comma.
    #expect(LiveTyping.calm("We fetched the update and we rest. Then, we go home", over: "We fetched the update and we rest then we go home", near: 12)
            == "We fetched the update and we rest then, we go home")
    #expect(LiveTyping.calm("We fetched the update and we rest, then, we go home", over: "We fetched the update and we rest. Then we go home", near: 12)
            == "We fetched the update and we rest. Then, we go home")
    // The same when the word after the held-back period is new or changed, and for a word with capitals of its own.
    #expect(LiveTyping.calm("Okay that is the plan. And so we go home now and then we sleep", over: "Okay that is the plan so we go home now and then we sleep", near: 12)
            == "Okay that is the plan and so we go home now and then we sleep")
    #expect(LiveTyping.calm("We checked the build, and then we go home and we sleep until morning", over: "We checked the build. Then we go home and we sleep until the morning", near: 12)
            == "We checked the build. And then we go home and we sleep until morning")
    #expect(LiveTyping.calm("We watched it. On YouTube later with the API open", over: "We watched it on youtube later with the api open", near: 12)
            == "We watched it on youtube later with the API open")
    #expect(LiveTyping.written("¿Qué") == LiveTyping.written("qué") && LiveTyping.written("word—") == "word")
    // A period in front of a word was said: ".5" is not "5", and a missing one is corrected at the stop like any
    // changed word.
    #expect(LiveTyping.written(".5") != LiveTyping.written("5") && LiveTyping.written(".env,") == ".env")
    var dose = LiveTyping(), dosed = ""
    let wrong = "The dose is 5 milligrams twice a day and then we stop", right = "The dose is .5 milligrams twice a day and then we stop"
    apply(say(wrong, to: &dose), to: &dosed)
    #expect(say(right, to: &dose).isEmpty)
    apply(dose.finish(right).edits, to: &dosed)
    #expect(dosed == right)
    // A guess with fewer words takes nothing back.
    var third = LiveTyping(), last = ""
    apply(say("Okay so the settings page. Into its own window", to: &third), to: &last)
    #expect(third.hear("Okay so the settings page.").isEmpty && third.settle().isEmpty)
    #expect(last == "Okay so the settings page. Into its own window" && third.typed == last)
    // A sign that was said is no punctuation: missed live, it is corrected like any changed word.
    var fourth = LiveTyping(), flag = ""
    let spoken = "Run the build again with verbose so we can see which step fails on the new machine"
    apply(fourth.hear(spoken) + fourth.hear(spoken) + fourth.hear(spoken), to: &flag)
    apply(fourth.finish("Run the build again with --verbose so we can see which step fails on the new machine.").edits, to: &flag)
    #expect(flag == "Run the build again with --verbose so we can see which step fails on the new machine.")
    #expect(LiveTyping.written("$5,") == "$5" && LiveTyping.written("12%") != LiveTyping.written("12") && LiveTyping.written("“Then,”") == "then")
    // Near the end the guess is written as it is, and a short text is never held back.
    #expect(LiveTyping.calm("Hi there, Sam", over: "Hi there Sam", near: 12) == "Hi there, Sam")
    #expect(LiveTyping.calm("We fetched it, and then we rest", over: "We fetched it and then we rest", near: 40) == "We fetched it, and then we rest")
}

/// Random dictations whose commas and periods the recognizer keeps changing its mind about, with a changed or added
/// word now and then: nothing but the newest word is ever taken back before the stop, the field always ends holding
/// every word of the finished text, never a capital without a sentence end before it or a sentence end without a
/// capital after it, and the stop takes back only a short tail unless a word changed.
@Test func liveTypingStaysCoherentWhenMarksComeLate() {
    struct Random {
        var state: UInt64
        mutating func next(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(count))
        }
    }
    let vocabulary = ["we", "fetched", "the", "update", "and", "then", "rest", "so", "go", "home", "now", "check", "build", "plan",
                      "okay", "that", "is", "it", "after", "pick", "up", "milk", "today", "works", "still", "feed", "window", "page"]
    func apply(_ edits: [LiveTyping.Edit], to field: inout String) -> Int {
        var back = 0
        for edit in edits {
            switch edit {
            case .delete(let count): field.removeLast(count); back += count
            case .type(let text): field += text
            }
        }
        return back
    }
    /// The words with the marks one pass would give them, and the capitals those marks bring.
    func written(_ words: [String], marks: [Int]) -> String {
        var out: [String] = []
        for (index, word) in words.enumerated() {
            let starts = index == 0 || marks[index - 1] == 2
            out.append((starts ? word.prefix(1).uppercased() + word.dropFirst() : word) + (index == words.count - 1 ? "" : ["", ",", "."][marks[index]]))
        }
        return out.joined(separator: " ")
    }
    var random = Random(state: 11), wrong: [String] = [], longStops = 0, tookBack: [Int] = []
    for _ in 0..<1500 {
        var words = (0..<(8 + random.next(18))).map { _ in vocabulary[random.next(vocabulary.count)] }
        var marks = words.map { _ in [0, 0, 0, 0, 1, 2][random.next(6)] }
        var typing = LiveTyping(), field = "", changed = false
        var count = 1
        while count <= words.count {
            // A pass changes its mind about a mark somewhere behind, or about a word.
            if random.next(3) == 0 { marks[random.next(count)] = random.next(3) }
            if random.next(12) == 0 { words[random.next(count)] = vocabulary[random.next(vocabulary.count)]; changed = true }
            let guess = written(Array(words[..<count]), marks: marks)
            // (A pause after some of them: the whole guess goes in.)
            let edits = typing.hear(guess) + typing.hear(guess) + typing.hear(guess) + (random.next(3) == 0 ? typing.settle() : [])
            let back = apply(edits, to: &field)
            if back > 0 { tookBack.append(back) }
            count += 1 + random.next(3)
        }
        if random.next(4) == 0 { words[random.next(words.count)] = "changed"; changed = true }
        marks[random.next(words.count)] = random.next(3)
        let finished = written(words, marks: marks) + "."
        let back = apply(typing.finish(finished).edits, to: &field)
        if !changed, back > LiveTyping.nearAtTheStop + 8 { longStops += 1 }
        let got = field.split(separator: " "), want = finished.split(separator: " ")
        var fine = got.map(LiveTyping.written) == want.map(LiveTyping.written) && field == typing.typed
        for (index, word) in got.enumerated() where index > 0 && fine {
            let after = got[index - 1].last.map { ".!?".contains($0) } ?? false
            fine = (word.first?.isUppercase ?? false) == after
        }
        if !fine { wrong.append("\(field) | \(finished)") }
    }
    #expect(longStops == 0)
    // Only the newest two words are typed again: two words of this vocabulary and their marks at most.
    #expect((tookBack.max() ?? 0) <= 2 * 8 + 1 && tookBack.count < 1_200, "\(tookBack.count) times, the most \(tookBack.max() ?? 0)")
    print("live typing: a newest word or two typed again \(tookBack.count) times in 1,500 random dictations")
    // A handful may keep a capital: the word after a held-back period keeps it when the system's name tagger takes it
    // for a name ("Up" once in these 1,500), as a real name there should. Without the rule it is hundreds.
    #expect(wrong.count <= 15, "\(wrong.count) wrong, first: \(wrong.prefix(4).joined(separator: " ;; "))")
}

/// "Show words instantly": the streaming recognizer's words have no capitals or marks of their own, so the passes'
/// are written in full while speaking and at the stop, however far back, also after a guess that was only remembered.
@Test func liveTypingWritesStreamedWordsAsThePassesHaveThem() {
    var typing = LiveTyping(), field = ""
    apply(typing.hear("okay so the next thing i want to do is move the settings page into its own window", firm: true), to: &field)
    _ = typing.hear("okay so the next thing i want to do is move the settings page into its own window and", typing: false)
    apply(typing.hear("Okay, so the next thing I want to do is move the settings page into its own window, and then", firm: true), to: &field)
    #expect(field == "Okay, so the next thing I want to do is move the settings page into its own window, and then")
    _ = typing.hear("Okay, so the next thing I want to do is move the settings page into its own window, and then we", typing: false, firm: true)
    apply(typing.finish("Okay. So the next thing I want to do is move the settings page into its own window, and then we rest.").edits, to: &field)
    #expect(field == "Okay. So the next thing I want to do is move the settings page into its own window, and then we rest.")
}

/// The person clicked somewhere else: the typed words stay, nothing more is typed, and the stop delivers only the
/// words after them.
@Test func liveTypingLeavesWordsBehindAndTheStopDeliversTheRest() {
    var typing = LiveTyping(), field = ""
    apply(say("Send the report to the team", to: &typing), to: &field)
    #expect(field == "Send the report to the team")
    typing.leave()
    #expect(typing.typed == "" && typing.left == ["send", "the", "report", "to", "the", "team"])
    #expect(typing.hear("Send the report to the team and copy me on it", typing: false).isEmpty)
    #expect(typing.remainder(of: "Send the report to the team and copy me on it.") == "and copy me on it.")
    // Nothing of it is taken back either.
    #expect(typing.erase().isEmpty)
}

/// The finished text joined more onto the last left word ("dash", "dot com", a clock time): the rest of that word
/// is still owed. A live guess never ends on the spoken mark itself (`SpokenJoiners.apply(open:)`), so the left
/// words never do either.
@Test func liveTypingRemainderKeepsWhatWasJoinedOntoTheLastLeftWord() {
    func remainder(left: String, finished: String, seam: Bool = false) -> String {
        var typing = LiveTyping(), field = ""
        _ = typing.hear(SpokenJoiners.apply(left, open: true))
        apply(typing.settle(), to: &field)
        typing.leave()
        return typing.remainder(of: finished, seam: seam)
    }
    #expect(remainder(left: "Name it maple", finished: "Name it maple-design is great.") == "-design is great.")
    #expect(remainder(left: "Name it maple dash", finished: "Name it maple-design is great.") == "-design is great.")
    #expect(remainder(left: "Name it maple dash", finished: "Name it maple-design") == "-design")
    #expect(remainder(left: "Name it maple dash", finished: "Name it maple-design", seam: true) == "-design")
    #expect(remainder(left: "Go to example dot", finished: "Go to example.com and sign up") == ".com and sign up")
    #expect(remainder(left: "Go to www dot example dot", finished: "Go to www.example.com and sign up today.") == ".com and sign up today.")
    #expect(remainder(left: "Go to www dot", finished: "Go to www.example.com and sign up today.") == ".example.com and sign up today.")
    #expect(remainder(left: "Git commit dash", finished: "Git commit -m fix it") == "-m fix it")
    #expect(remainder(left: "Add the key to the dot", finished: "Add the key to the .env file") == ".env file")
    #expect(remainder(left: "It is at example dot com slash", finished: "It is at example.com/docs today") == "/docs today")
    #expect(remainder(left: "Call it user underscore", finished: "Call it user_name now") == "_name now")
    #expect(remainder(left: "Run it with dash dash", finished: "Run it with --help now") == "--help now")
    #expect(remainder(left: "Pages 5", finished: "Pages 5-10 of the report") == "-10 of the report")
    #expect(remainder(left: "Meet at 3", finished: "Meet at 3:30 today.") == ":30 today.")
    #expect(remainder(left: "They all dash", finished: "They all dash.") == "dash.")
    // A word the finished text only respelled or closed is covered as before.
    #expect(remainder(left: "We walk", finished: "We walked back home") == "back home")
    #expect(remainder(left: "I think it", finished: "I think it's fine") == "fine")
    #expect(remainder(left: "The build passed", finished: "The build passed. Ship it.") == "Ship it.")
}

/// No spoken word is lost across a spoken joiner when live-typed words are left in a field: random sentences with
/// "dash", "hyphen" and "dot" in them, left after every word, with and without the mark a pause puts after a guess.
/// What is in the field plus what the stop pastes must hold every word of the finished text, in order.
@Test func leavingTheFieldNeverLosesAWordAcrossASpokenJoiner() {
    struct Random {
        var state: UInt64
        mutating func next(_ count: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(count))
        }
    }
    let vocabulary = ["name", "it", "maple", "design", "run", "with", "help", "go", "to", "example", "www", "now", "ready", "is",
                      "blue", "the", "a", "say", "com", "com", "io", "md", "env", "m", "type", "and", "or", "user", "5", "10",
                      "dash", "dash", "dash", "hyphen", "dot", "dot", "dot", "slash", "slash", "underscore"]
    let marks: Set<String> = ["dash", "hyphen", "dot", "slash", "underscore"]
    func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    /// Every finished word is there, in order, and nothing else. Where the guess had only the first letter of its
    /// last word, that letter may stand for the word, or stand beside it: a half-typed word left in a field is
    /// never repaired, with or without spoken marks.
    func holds(_ got: [String], _ finished: [String], partial: Bool) -> Bool {
        guard partial else { return got == finished }
        var at = 0
        for word in finished {
            guard let found = got[at...].firstIndex(where: { $0 == word || ($0.count == 1 && word.hasPrefix($0)) }) else { return false }
            at = found + 1
        }
        return true
    }
    var random = Random(state: 7), lost: [String] = [], joins = 0
    for _ in 0..<3000 {
        let spoken = (0..<(3 + random.next(8))).map { _ in vocabulary[random.next(vocabulary.count)] }
        let finished = SmartInsertion.capitalizingFirstWord(SpokenJoiners.apply(spoken.joined(separator: " ") + "."))
        if finished.count < spoken.joined(separator: " ").count + 1 { joins += 1 }
        for cut in 1..<spoken.count {
            // "~": the guess has only the first letter of its last word so far (the streaming recognizer writes a
            // word piece by piece).
            for pause in ["", ".", ",", "~"] {
                var heard = Array(spoken[..<cut])
                if pause == "~" {
                    // (Half a spoken mark is not told from a word by this test's word list.)
                    // (Nor is a first letter that is a word of its own, "m" of "maple". And a half-typed word left in a
                    // field is never repaired: a word the next mark joins onto it is lost with its other half.)
                    guard !marks.contains(heard[cut - 1]), heard[cut - 1].count > 1, !vocabulary.contains(String(heard[cut - 1].prefix(1))),
                          cut == spoken.count || !marks.contains(spoken[cut]) else { continue }
                    heard[cut - 1] = String(heard[cut - 1].prefix(1))
                }
                let guess = SmartInsertion.capitalizingFirstWord(SpokenJoiners.apply(heard.joined(separator: " ") + (pause == "~" ? "" : pause), open: true))
                for seam in [false, true] {
                    var typing = LiveTyping(), field = ""
                    _ = typing.hear(guess)
                    apply(typing.settle(), to: &field)
                    typing.leave()
                    let rest = typing.remainder(of: finished, seam: seam)
                    if !holds(words(field + " " + rest), words(finished), partial: pause == "~") { lost.append("\(guess) | \(finished) | \(field) + \(rest)") }
                }
            }
        }
    }
    #expect(joins > 600, "\(joins)")
    #expect(lost.isEmpty, "\(lost.count) lost, first: \(lost.prefix(8).joined(separator: " ;; "))")
}

/// The cursor is still after the left words but the field cannot be read (a terminal after a click): what belongs
/// between them and the rest goes in too, the mark held back after them and a space.
@Test func liveTypingRemainderJoinsOntoLeftWordsWhereTheFieldCannotBeRead() {
    var typing = LiveTyping(), field = ""
    _ = typing.hear("The build passed.")
    apply(typing.settle(), to: &field)
    #expect(field == "The build passed")
    typing.leave()
    #expect(typing.remainder(of: "The build passed. Ship it now, please.", seam: true) == ". Ship it now, please.")
    // Where the paste can read the field it fits the words itself: only the words.
    #expect(typing.remainder(of: "The build passed. Ship it now, please.") == "Ship it now, please.")

    // Two words are never run together, and a line break after the left words is kept.
    var other = LiveTyping()
    _ = say("Hello world", to: &other)
    other.leave()
    #expect(other.remainder(of: "Hello world, how are you?", seam: true) == ", how are you?")
    #expect(other.remainder(of: "Hello world,\nThanks for the update.", seam: true) == ",\nThanks for the update.")
    // Every word was left behind: only the closing mark is still owed.
    #expect(other.remainder(of: "Hello world.", seam: true) == "." && other.remainder(of: "Hello world.") == "")
}

@Test func liveTypingFindsWhereLeftWordsEndWhenTheFinishedTextChangedThem() {
    func covered(_ left: String, _ words: String) -> Int {
        LiveTyping.covered(left.split(separator: " ").map(String.init), in: words.split(separator: " ").map(String.init))
    }
    // One word of what was left behind is heard differently later; the rest still lines up.
    #expect(covered("send the report to the team", "send a report to the team and copy") == 6)
    // The last left word itself was changed: the word after it is still to come ("house", "back", "here", "in").
    #expect(covered("put it over there", "put it over their house now") == 4)
    #expect(covered("we walk", "we walked back home") == 2)
    #expect(covered("the store", "the stores here today") == 2)
    #expect(covered("at noon", "at nine in the morning") == 2)
    #expect(covered("get a", "get the banana") == 2)
    // Two or more left words the text has other words for were made up: the words said there are still to come.
    #expect(covered("we should be able", "we should go home now") == 2)
    // Two words written differently are still those words.
    #expect(covered("i think there going to", "i think they're going too far") == 5)
    #expect(covered("its time to go to bobs", "it's time to go to bob's place") == 6)
    #expect(LiveTyping.alike("there", "they're") && LiveTyping.alike("rose", "row") && !LiveTyping.alike("noon", "nine") && !LiveTyping.alike("a", "the"))
    // The same word a little further on is not the left one: the words before it are still to come.
    #expect(covered("i think that", "i think the thing that matters is speed") == 3)
    #expect(covered("call me at", "call me after that at five") == 3)
    // The finished text heard a word in the middle that the first pass missed: "to" is still the last left word.
    #expect(covered("i want to", "i want you to go now") == 4)
    // Two words became one, or one became two: the left word is never typed again.
    #expect(covered("pick up ice cream today", "pick up icecream today and milk") == 4)
    #expect(covered("pick up icecream", "pick up ice cream today") == 4)
    #expect(covered("pick up ice cream", "pick up icecream today") == 3)
    // The finished text is shorter than what was left.
    #expect(covered("one two three", "one two") == 2)
    #expect(covered("", "one") == 0)
}

/// The person only clicked where the cursor already was: the words are this dictation's own again.
@Test func liveTypingTakesLeftWordsUpAgainWhenTheCursorIsStillAfterThem() {
    var typing = LiveTyping(), field = "Dear team,"
    typing.attach(before: field, after: "")
    apply(say("thanks for the update", to: &typing), to: &field)
    typing.leave()
    #expect(typing.abandonedText == " thanks for the update" && typing.left == ["thanks", "for", "the", "update"])
    _ = typing.hear("thanks for the updates and", typing: false)
    typing.reclaim()
    #expect(typing.typed == " thanks for the update" && typing.left.isEmpty && typing.abandonedText == nil)
    // Typed on and finished in place, like words that were never left.
    apply(say("thanks for the updates and the notes", to: &typing), to: &field)
    #expect(field == "Dear team, thanks for the updates and the notes")
    apply(typing.finish("Thanks for the updates and the notes.").edits, to: &field)
    #expect(field == "Dear team, thanks for the updates and the notes.")
}

/// A run of key presses cut short: what is really in the field is what was left, word for word.
@Test func liveTypingLeavesWhatIsReallyInTheFieldWhenKeyPressesAreCutShort() {
    var typing = LiveTyping()
    _ = typing.hear("pick up oat milk"); _ = typing.hear("pick up oat milk"); _ = typing.hear("pick up oat milk")
    // A correction was taking the last word back when focus moved: only "pick up oat" is still there.
    typing.leave(holding: "pick up oat")
    #expect(typing.left == ["pick", "up", "oat"])
    #expect(typing.remainder(of: "Pick up oat milk today.") == "milk today.")
}

/// Key presses that never reached the field: nothing counts as typed, so the stop delivers everything.
@Test func liveTypingDisownsWordsTheFieldNeverTook() {
    var typing = LiveTyping()
    _ = say("first words then more", to: &typing)
    #expect(typing.typed == "first words then more")
    typing.disown()
    #expect(typing.typed == "" && typing.left.isEmpty)
    #expect(typing.remainder(of: "First words then more.") == "First words then more.")
    #expect(typing.erase().isEmpty)
}

@Test func liveTypingEraseTakesBackOnlyThisRunsWords() {
    var typing = LiveTyping(), field = "Dear team,"
    typing.attach(before: field, after: "")
    apply(say("thanks for the update", to: &typing), to: &field)
    #expect(field == "Dear team, thanks for the update")
    apply(typing.erase(), to: &field)
    #expect(field == "Dear team,")
    #expect(typing.erase().isEmpty)
}

@Test func liveTypingRememberedGuessTypesNothing() {
    var typing = LiveTyping()
    #expect(typing.hear("Nothing can be typed right now", typing: false).isEmpty)
    #expect(typing.hear("Nothing can be typed right now", typing: false).isEmpty)
    #expect(typing.typed == "")
    // Once it can type, the words both guesses agreed on arrive.
    #expect(typing.hear("Nothing can be typed right now at all") == [.type("Nothing can be typed right now")])
}

/// Recorded guesses through the typing rule, without a recognizer: `MOUTHY_TEST_TYPING_TRACE=<tsv>[:<tsv>…]`, the
/// files `liveTypingReplay` writes with `MOUTHY_LIVE_TYPING_OUT` (time in ms, "guess", text; a `FINAL` row). Fails if
/// more than a newest word or two is taken back before the stop or the field does not end as the finished text. Prints how many typed
/// words the finished text writes differently and how much the stop had to take back.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_TYPING_TRACE"] != nil))
func recordedGuessesAreTypedWithoutTakingAnythingBack() throws {
    for path in (ProcessInfo.processInfo.environment["MOUTHY_TEST_TYPING_TRACE"] ?? "").split(separator: ":") {
        let rows = try String(contentsOfFile: String(path), encoding: .utf8).split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
        // A trace that marks the guesses heard at a pause is typed as the app types with such a recognizer: a
        // phrase at each pause. One without them, from the guesses and the 0.8 s rule.
        let pauses = Dictionary(rows.compactMap { row -> (Int, LiveTyping.Pause)? in
            guard row.count > 1, row[1] == "atpause", let time = Int(row[0]) else { return nil }
            return (time, row.count > 2 && row[2] == "talkedon" ? .talkedOn : .held)
        }, uniquingKeysWith: { first, _ in first })
        var typing = LiveTyping(); typing.attach(before: "", after: "")
        typing.settlesAtPauses = !pauses.isEmpty
        var when: [Int] = [], fieldWords: [String] = [], clock = 0
        var field = "", typedCount = 0, last = 0, final = "", tookBack = 0
        let longest = 24
        var settled = true
        func apply(_ edits: [LiveTyping.Edit], speaking: Bool) -> Int {
            var back = 0
            for edit in edits {
                switch edit {
                case .delete(let count): back += count; field.removeLast(count)
                case .type(let text): field += text; typedCount += text.count
                }
            }
            let now = LiveTyping.words(field[...]).map(LiveTyping.plain)
            let keep = zip(fieldWords, now).prefix { $0.0 == $0.1 }.count
            when = Array(when.prefix(keep)) + Array(repeating: clock, count: now.count - keep); fieldWords = now
            // Only the newest two words may be typed again.
            if speaking, back > 0 { tookBack += back; #expect(back <= longest, "took \(back) characters back while speaking in \(path)") }
            return back
        }
        for row in rows {
            if row.first == "FINAL", row.count > 1 { final = String(row[1]) }
            guard row.count > 2, row[1] == "guess", let time = Int(row[0]) else { continue }
            clock = time
            // The pause rule without marks: no newer guess for 0.8 s.
            if !typing.settlesAtPauses, !settled, time - last > 800 { _ = apply(typing.settle(), speaking: true) }
            _ = apply(typing.hear(String(row[2]), pause: pauses[time]), speaking: true)
            last = time; settled = false
        }
        if !typing.settlesAtPauses { _ = apply(typing.settle(), speaking: true) }
        let before = LiveTyping.words(field[...]).map(LiveTyping.plain)
        let wanted = LiveTyping.words(final[...]).map(LiveTyping.plain)
        let finished = typing.finish(final)
        let back = apply(finished.edits, speaking: false)
        #expect(field == typing.typed)
        let after = LiveTyping.words(field[...]).map(LiveTyping.plain)
        // The words of the field and of the finished text that the other does not have, in order.
        var table = Array(repeating: Array(repeating: 0, count: wanted.count + 1), count: after.count + 1)
        for i in after.indices.reversed() { for j in wanted.indices.reversed() {
            table[i][j] = after[i] == wanted[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1]) } }
        var i = 0, j = 0, extra: [String] = [], missing: [String] = []
        while i < after.count || j < wanted.count {
            if i < after.count, j < wanted.count, after[i] == wanted[j] { i += 1; j += 1 }
            else if j == wanted.count || (i < after.count && table[i + 1][j] >= table[i][j + 1]) { extra.append(after[i]); i += 1 }
            else { missing.append(wanted[j]); j += 1 }
        }
        let spoken: [(String, Int)] = rows.first { $0.first == "SPOKEN" }.map { $0[1].split(separator: " ").compactMap { w in
            let p = w.split(separator: "@"); return p.count == 2 ? (LiveTyping.plain(String(p[0])), Int(p[1]) ?? 0) : nil } } ?? []
        var lags: [Int] = [], ends: [Int] = [], k = 0
        for (index, word) in fieldWords.enumerated() where index < when.count {
            guard let found = spoken[k...].firstIndex(where: { $0.0 == word }), found - k < 6 else { continue }
            let lag = when[index] - spoken[found].1
            lags.append(lag)
            if found + 1 == spoken.count || spoken[found + 1].1 - spoken[found].1 > 700 { ends.append(lag) }
            k = found + 1
        }
        lags.sort(); ends.sort()
        if !lags.isEmpty { print("  lag \((String(path) as NSString).lastPathComponent): median \(lags[lags.count / 2]) p90 \(lags[lags.count * 9 / 10]); phrase ends median \(ends.isEmpty ? -1 : ends[ends.count / 2]) (\(ends.count))") }
        if typing.settlesAtPauses {
            // Nothing is taken back, while speaking or at the stop, and the field holds what the pauses' passes
            // heard: where the stop's own pass hears a settled word differently, the settled word stays.
            #expect(tookBack == 0 && back == 0, "took back \(tookBack) while speaking and \(back) at the stop in \(path)")
        } else {
            #expect(after == wanted, "the field does not end as the finished text in \(path)")
        }
        print("typing trace \((String(path) as NSString).lastPathComponent): typed \(typedCount) characters, \(before.count) words before the stop, \(tookBack) characters taken back while speaking, the stop took back \(back); after it the field has \(extra.count) words the finished text does not (\(extra.prefix(12).joined(separator: " "))) and lacks \(missing.count) (\(missing.prefix(12).joined(separator: " ")))")
    }
}
