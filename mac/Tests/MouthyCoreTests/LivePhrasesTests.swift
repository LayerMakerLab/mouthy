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
