import Testing
import Foundation
@testable import MouthyCore

private func tone(_ seconds: Double, level: Float = 0.1) -> [Float] {
    (0..<Int(seconds * 16_000)).map { level * Float(sin(Double($0) * 0.2)) }
}
private func quiet(_ seconds: Double, level: Float = 0) -> [Float] {
    (0..<Int(seconds * 16_000)).map { level * Float(sin(Double($0) * 1.3)) }
}

@Test func pausesFindSpeechRunsAndTheirEnds() {
    var pauses = SpeechPauses()
    let audio = quiet(0.3) + tone(1.0) + quiet(0.5) + tone(0.8) + quiet(0.4)
    // Fed in uneven pieces, like microphone buffers.
    var index = 0
    for size in [1_000, 4_321, 777, 16_000, 100_000] where index < audio.count {
        let end = min(audio.count, index + size)
        pauses.feed(Array(audio[index..<end]))
        index = end
        #expect(pauses.received == index)
        #expect(pauses.scanned <= index && index - pauses.scanned < SpeechPauses.frame)
    }
    #expect(pauses.heardSpeech)
    #expect(pauses.onsets.count == 2)
    #expect(abs(pauses.onsets[0] - 4_800) <= SpeechPauses.frame)
    #expect(abs(pauses.onsets[1] - 28_800) <= SpeechPauses.frame)
    #expect(abs(pauses.lastSpeechEnd - 41_600) <= SpeechPauses.frame)
    #expect(pauses.onset(atOrAfter: 20_000) == pauses.onsets[1])
}

@Test func pausesIgnoreRoomNoiseAndStillHearSpeech() {
    var pauses = SpeechPauses()
    pauses.feed(quiet(1.0, level: 0.003) + tone(0.5, level: 0.05) + quiet(0.5, level: 0.003))
    #expect(pauses.onsets.count == 1)
    #expect(!pauses.hasSpeech(quiet(0.5, level: 0.003)[...]))
    #expect(pauses.hasSpeech(tone(0.3, level: 0.05)[...]))
}

@Test func silenceIsNeverSpeech() {
    var pauses = SpeechPauses()
    pauses.feed(quiet(2))
    #expect(!pauses.heardSpeech)
    #expect(pauses.lastSpeechEnd == 0)
}

@Test func phrasesAfterShortPausesContinueTheSentence() {
    #expect(PhraseJoiner.join([("So I was thinking.", 0), ("About the launch.", 0.4)]) == "So I was thinking about the launch.")
    #expect(PhraseJoiner.join([("We met Sarah.", 0), ("Sarah liked it.", 0.3)]).hasSuffix("Sarah liked it."))
    #expect(PhraseJoiner.join([("Call me.", 0), ("I will be home.", 0.3)]) == "Call me I will be home.")
    #expect(PhraseJoiner.join([("Is it done?", 0), ("Yes.", 0.3)]) == "Is it done? Yes.")
}

@Test func phrasesContinuingAnOpenSentenceLoseTheirCapital() {
    // The recognizer capitalizes every phrase; a phrase after a short pause, or after a clause left open
    // with a comma, continues the sentence.
    #expect(PhraseJoiner.join([("I want to go", 0), ("To the store.", 0.3)]) == "I want to go to the store.")
    #expect(PhraseJoiner.join([("I want to,", 0), ("Go to the store.", 0.3)]) == "I want to, go to the store.")
    #expect(PhraseJoiner.join([("Run the whole test script,", 0), ("Then push the branch.", 1.0)]) == "Run the whole test script, then push the branch.")
    #expect(PhraseJoiner.join([("First,", 0), ("Tuesday works.", 1.0)]) == "First, Tuesday works.")
    #expect(PhraseJoiner.join([("He said \"stop.\"", 0), ("Then left.", 1.0)]) == "He said \"stop.\" Then left.")
    #expect(PhraseJoiner.join([("Let's meet at 3 p.m.", 0), ("Tomorrow works.", 0.3)]) == "Let's meet at 3 p.m. tomorrow works.")
}

@Test func partsCutAtLongPausesGetTheirPeriod() {
    // A part closed at a long pause ends without punctuation (the recognizer never heard the sentence end);
    // recognizing the whole file writes "GitHub. The handoff".
    #expect(PhraseJoiner.join([("Push the branch to the hub but not to GitHub", 0), ("The handoff needs the numbers.", 1.1)])
            == "Push the branch to the hub but not to GitHub. The handoff needs the numbers.")
    #expect(PhraseJoiner.join([("It took 20", 0), ("Minutes.", 0.3)]) == "It took 20 minutes.")
}

@Test func phrasesAfterLongPausesStartNewSentences() {
    #expect(PhraseJoiner.join([("First point.", 0), ("Second point.", 1.2)]) == "First point. Second point.")
    #expect(PhraseJoiner.join([("", 0), ("  Only this.  ", 0.2), ("", 3)]) == "Only this.")
}

@Test func longestPauseIsFoundBetweenSpeechRuns() {
    var pauses = SpeechPauses()
    pauses.feed(tone(1) + quiet(0.3) + tone(1) + quiet(0.9) + tone(1) + quiet(0.2) + tone(1))
    let pause = pauses.longestPause(from: 0, to: pauses.scanned)
    #expect(pause != nil)
    #expect(abs((pause?.start ?? 0) - 36_800) <= SpeechPauses.frame)
    #expect(abs((pause?.end ?? 0) - 51_200) <= SpeechPauses.frame)
    #expect(pauses.longestPause(from: 60_000, to: pauses.scanned).map { $0.end - $0.start } ?? 0 < 4_000)
}

@Test func keyClicksAreNotSpeech() {
    var pauses = SpeechPauses()
    // A sentence, then the double-tap that stops dictation: two 20 ms clicks 150 ms apart.
    let clicks = quiet(0.4) + tone(0.02, level: 0.3) + quiet(0.15) + tone(0.02, level: 0.3) + quiet(0.1)
    pauses.feed(tone(1.0) + clicks)
    #expect(pauses.onsets.count == 1)
    #expect(abs(pauses.lastSpeechEnd - 16_000) <= SpeechPauses.frame)
    #expect(!pauses.hasSpeech(clicks[...]))
    #expect(pauses.hasSpeech(tone(0.3)[...]))
    #expect(!pauses.hasSpeech(tone(0.1)[...]))
}

@Test func softWordsAfterLoudSpeechStillCountAsSound() {
    // A loud phrase, then a soft ending under the speech threshold (RMS about 0.0028 against 0.004) over a quiet room.
    var pauses = SpeechPauses()
    let audio = quiet(0.3, level: 0.0004) + tone(1.0) + quiet(0.4, level: 0.0004) + tone(0.8, level: 0.004) + quiet(0.4, level: 0.0004)
    pauses.feed(audio)
    #expect(abs(pauses.lastSpeechEnd - 20_800) <= SpeechPauses.frame)    // the speech threshold stops at the loud phrase
    #expect(abs(pauses.lastSoundEnd - 40_000) <= 2 * SpeechPauses.frame) // the quiet check hears the soft ending
    let soft = audio[27_200..<40_000]
    #expect(!pauses.hasSpeech(soft))
    #expect(pauses.mightHoldWords(soft))
}

@Test func roomNoiseAndKeyClicksMightNotHoldWords() {
    var pauses = SpeechPauses()
    var audio = quiet(1.0, level: 0.0006)
    for click in [6_000, 8_400] { for i in 0..<320 { audio[click + i] = (i % 2 == 0 ? 0.3 : -0.3) * Float(320 - i) / 320 } }
    pauses.feed(audio)
    #expect(!pauses.mightHoldWords(audio[...]))
    #expect(pauses.lastSoundEnd == 0)
}

// A long dictation on a busy Mac: soft words under the speech threshold were taken for a pause, so a part could be
// cut inside them (a word repeated or lost), and the pause between parts was measured from a stale loud-speech end,
// so a breath looked like seconds and kept a period mid-sentence ("noon. after").

@Test func softWordsAreNeverAPause() throws {
    var pauses = SpeechPauses()
    // Loud speech, soft words under the speech threshold, a real silence, then loud speech again.
    pauses.feed(quiet(0.3) + tone(1.0) + tone(0.6, level: 0.004) + quiet(0.5) + tone(0.8) + quiet(0.3))
    let pause = try #require(pauses.longestPause(from: 0, to: pauses.scanned))
    // The pause is the silence after the soft words, not the soft words themselves.
    #expect(abs(pause.start - Int(1.9 * 16_000)) <= SpeechPauses.frame * 3)
    #expect(abs(pause.end - Int(2.4 * 16_000)) <= SpeechPauses.frame * 3)
}

@Test func silenceAfterAPartIsMeasuredInSound() throws {
    var pauses = SpeechPauses()
    pauses.feed(quiet(0.3) + tone(1.0) + tone(0.6, level: 0.004) + quiet(0.4) + tone(0.5) + quiet(0.2))
    // A cut inside sound (no pause there, soft words included): the next part continues at once.
    #expect(pauses.silence(after: Int(1.0 * 16_000)) == 0)
    #expect(pauses.silence(after: Int(1.7 * 16_000)) == 0)
    // After the soft words end, the silence runs to the next sound.
    let end = try #require(pauses.soundEnds.first)
    let silence = try #require(pauses.silence(after: end))
    #expect(abs(silence - Int(0.4 * 16_000)) <= SpeechPauses.frame * 4)
}

@Test func aLowercasePhraseNeverFollowsASentenceEnd() {
    // A recognizer that starts a phrase in lowercase heard it begin mid-sentence.
    #expect(PhraseJoiner.join([("We met at noon.", 0), ("after lunch we left.", 1.2)]) == "We met at noon. After lunch we left.")
    #expect(PhraseJoiner.join([("Put the lamp on the left?", 0), ("side of the desk.", 0.3)]) == "Put the lamp on the left side of the desk.")
    #expect(PhraseJoiner.join([("Is it done?", 0), ("Yes.", 0.3)]) == "Is it done? Yes.")
    #expect(PhraseJoiner.join([("Bring the cable.", 0), ("iPhone first.", 1.2)]) == "Bring the cable. iPhone first.")
}

@Test func contextDecodesDecideTheBoundary() {
    // Heard with the audio before them, lowercase words continue the sentence whatever the pause.
    #expect(PhraseJoiner.join("The best part of the trip was.", heard: ContextWords(before: "of the trip was", after: "the food."), gap: 1.5)
            == "The best part of the trip was the food.")
    #expect(PhraseJoiner.join("Hey Mouthy.", heard: ContextWords(before: "hey mouthy", after: "start a ten-minute timer."), gap: 0.9)
            == "Hey Mouthy start a ten-minute timer.")
    // A capital after a long pause starts a new sentence.
    #expect(PhraseJoiner.join("We bought bread.", heard: ContextWords(before: "bought bread", after: "Milk was sold out."), gap: 1.0)
            == "We bought bread. Milk was sold out.")
}

@Test func contextDecodesNeverRepeatTheBoundaryWord() {
    // The word ending at the cut was timed after it: the decode never heard it in its context, so it is the same word.
    #expect(PhraseJoiner.join("the old train station still stands.", heard: ContextWords(before: "train station still", after: "stands. Nobody knows why."), gap: 0.3)
            == "the old train station still stands. Nobody knows why.")
    #expect(PhraseJoiner.join("turn left, then turn right", heard: ContextWords(before: "turn left then turn", after: "right."), gap: 0.2)
            == "turn left, then turn right")
    // Said twice: the decode heard it in its context and again after the cut.
    #expect(PhraseJoiner.join("Check check", heard: ContextWords(before: "check check", after: "check."), gap: 0.3) == "Check check check.")
    // Without token times (Intel) nothing is dropped.
    #expect(PhraseJoiner.join("Check check", heard: ContextWords(after: "check."), gap: 0.3) == "Check check check.")
}

/// Unvoiced noise like an inhale: deterministic, about 0.5 zero crossings per sample.
private func breath(_ seconds: Double, level: Float) -> [Float] {
    var state: UInt32 = 12_345
    return (0..<Int(seconds * 16_000)).map { _ in
        state = state &* 1_664_525 &+ 1_013_904_223
        return level * (Float(state >> 8) / Float(1 << 24) * 2 - 1) * 1.7
    }
}

@Test func aBreathBetweenSentencesDoesNotShortenThePause() throws {
    // "That's the plan." 0.3 s of silence, an audible inhale (soft, then loud enough to pass the speech threshold),
    // a breath of quiet, "Next we ship."
    for level: Float in [0.003, 0.02] {
        var pauses = SpeechPauses()
        pauses.feed(quiet(0.3) + tone(1.0) + quiet(0.3) + breath(0.35, level: level) + quiet(0.1) + tone(1.0) + quiet(0.3))
        let end = try #require(pauses.wordEnds.first)
        let silence = try #require(pauses.silence(after: end))
        #expect(Double(silence) / 16_000 >= PhraseJoiner.sentencePause, "breath at \(level): \(silence)")
        #expect(pauses.wordOnsets.count == 2)
        // The breath is still sound: leftover audio holding only it is recognized when unsure.
        #expect(pauses.soundOnsets.count == 3)
    }
}

@Test func contextDecodesNeverTakeASentenceEndBeforeACapital() {
    #expect(PhraseJoiner.join("That's the plan.", heard: ContextWords(before: "the plan", after: "Next we ship."), gap: 0.3)
            == "That's the plan. Next we ship.")
    #expect(PhraseJoiner.join("That's the plan", heard: ContextWords(before: "the plan", after: "Next we ship."), gap: 1.0)
            == "That's the plan. Next we ship.")
}

@Test func numbersAndLowercaseTermsShowNoCase() {
    let terms = PhraseJoiner.lowercaseTerms(["npm", "Mouthy", "iPhone", "LLM", "ten-x"])
    #expect(terms == ["npm", "ten-x"])
    for gap in [0.3, 1.2] {
        #expect(PhraseJoiner.join([("We have 3 options.", 0), ("2 are bad.", gap)]) == "We have 3 options. 2 are bad.")
        #expect(PhraseJoiner.join([("Run the build.", 0), ("npm install fails.", gap)], keepCase: terms) == "Run the build. npm install fails.")
        #expect(PhraseJoiner.join("Run the build.", heard: ContextWords(before: "the build", after: "npm install fails."), gap: gap, keepCase: terms)
                == "Run the build. npm install fails.")
        #expect(PhraseJoiner.join("We have 3 options.", heard: ContextWords(before: "3 options", after: "2 are bad."), gap: gap)
                == "We have 3 options. 2 are bad.")
    }
    // A long pause after an open sentence adds the period but never capitalizes the term.
    #expect(PhraseJoiner.join([("Run the build", 0), ("npm install fails.", 1.2)], keepCase: terms) == "Run the build. npm install fails.")
    // An ordinary lowercase word still continues the sentence.
    #expect(PhraseJoiner.join("Run the build.", heard: ContextWords(before: "the build", after: "and wait."), gap: 1.2, keepCase: terms)
            == "Run the build and wait.")
}
