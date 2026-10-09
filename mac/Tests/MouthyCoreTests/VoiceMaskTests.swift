import Foundation
import Testing
@testable import MouthyCore

@Test func voiceAndItsPaddingStayAsRecorded() {
    let voiced = VoiceMask.voiced([0, 0, 0, 0, 0.9, 0, 0, 0, 0, 0], count: 10, threshold: 0.3, pad: 1)
    #expect(voiced == [false, false, false, true, true, true, false, false, false, false])
    // Unscored pieces (a short tail) count as voice.
    #expect(VoiceMask.voiced([0.1, 0.1], count: 3, threshold: 0.3, pad: 0) == [false, false, true])
    #expect(!VoiceMask.voiced([0.1, 0.2], count: 2, threshold: 0.3, pad: 2).contains(true))
}

@Test func otherSoundIsTurnedDownToARoomNeverToZero() {
    let chunk = 1_000
    // A loud cough (0.3) in the first piece, a quiet room (0.0005) in the second, speech (0.2) in the third.
    let samples = [Float](repeating: 0.3, count: chunk) + [Float](repeating: 0.0005, count: chunk) + [Float](repeating: 0.2, count: chunk)
    let out = VoiceMask.apply(samples, voiced: [false, false, true], chunk: chunk)
    #expect(abs(out[500] - VoiceMask.room) < 0.000_01, "the cough is turned down to the room's level")
    #expect(out[1_000..<1_840].allSatisfy { $0 == 0.0005 }, "a quiet room stays as recorded")
    #expect(out[2_000...].allSatisfy { $0 == 0.2 }, "speech stays as recorded")
    #expect(out.allSatisfy { $0 != 0 } && out.count == samples.count)
}

// "Only listen to my voice": which speech is someone else's, from the windows' similarity to the voiceprint.
@Test func speakerMaskKeepsThePersonAndUnsureSpeech() {
    let speech = [Bool](repeating: true, count: 14)
    // The person (high scores) for the first half, then another voice (low scores). A piece any matching window
    // covers is kept, so only pieces past the last matching window (4, pieces 4-11) are someone else's.
    let verdicts = SpeakerMask.verdicts(speech: speech, scores: [0: 0.85, 2: 0.8, 4: 0.6, 6: 0.1, 8: 0.05, 10: 0.05])
    #expect(verdicts.prefix(12).allSatisfy { $0 == .mine })
    #expect(verdicts.suffix(2).allSatisfy { $0 == .theirs })
    // Nothing scored yet: every word is kept (unsure), never dropped on a guess.
    #expect(SpeakerMask.verdicts(speech: speech, scores: [:]).allSatisfy { $0 == .unsure })
    // Silence between two voices: speech that starts fresh after it, unscored, is kept.
    let gap = [true, true, true, true, true, true, false, false, true, true]
    let fresh = SpeakerMask.verdicts(speech: gap, scores: [0: 0.1])
    #expect(fresh[0] == .theirs && fresh[8] == .unsure && fresh[9] == .unsure)
}

@Test func speakerMaskSimilarityAndCentroid() {
    #expect(abs(SpeakerMask.similarity([1, 0], [1, 0]) - 1) < 1e-6)
    #expect(abs(SpeakerMask.similarity([1, 0], [0, 1])) < 1e-6)
    #expect(SpeakerMask.similarity([], []) == 0)
    let centre = SpeakerMask.centroid([[2, 0], [0, 2]])
    #expect(abs(centre[0] - centre[1]) < 1e-6 && abs(centre[0] * centre[0] + centre[1] * centre[1] - 1) < 1e-5)
}

@Test func anotherVoiceBecomesRoomHissNotAQuietVoice() {
    let voice = (0..<1_200).map { Float(sin(Double($0) / 7)) * 0.1 }
    let out = VoiceMask.hush(voice, voices: [false, true, false], chunk: 400)
    #expect(out.count == voice.count)
    #expect(Array(out[0..<400]) == Array(voice[0..<400]))
    let middle = out[560..<640]
    #expect(middle.allSatisfy { abs($0) <= VoiceMask.room })
    #expect(VoiceMask.hush(voice, voices: [false, false, false], chunk: 400) == voice)
}

// Short windows inside the person's sentence: a piece is another voice alone only when every window around it is
// clearly closer to the other voices than to the voiceprint (the demo's numbers, VoicePrintProbe.probeDemo).
@Test func shortWindowsTurnDownOnlyClearlyAnotherVoice() {
    // A newscaster alone in the person's pause: both windows lean +0.57 and +0.45 to the other voices.
    #expect(SpeakerMask.clearlyTheirs(mine: [0.04, 0.07], theirs: [0.61, 0.52]))
    // Her "and" at the pause's end: one window leans +0.17, the other -0.04, so it is kept.
    #expect(!SpeakerMask.clearlyTheirs(mine: [0.26, 0.23], theirs: [0.22, 0.40]))
    // Her words: closer to the voiceprint.
    #expect(!SpeakerMask.clearlyTheirs(mine: [0.42, 0.49], theirs: [0.16, 0.17]))
    // Just under the margin, or a missing window: kept.
    #expect(!SpeakerMask.clearlyTheirs(mine: [0.10, 0.10], theirs: [0.19, 0.30]))
    #expect(!SpeakerMask.clearlyTheirs(mine: [], theirs: []))
}

/// Training keeps the voice heard most and leaves a TV out of the voiceprint, including what the TV leaves in the
/// person's own windows when it talks underneath them.
@Test func trainingKeepsTheVoiceHeardMostAndTakesTheOtherOut() {
    func unit(_ v: [Float]) -> [Float] { let l = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); return v.map { $0 / l } }
    let person: [Float] = [1, 0, 0, 0], tv: [Float] = [0, 1, 0, 0]
    // Ten windows of the person with the TV a little under them, four of the TV alone (before, between, after).
    let mixed = (0..<10).map { i in unit([1, 0.3, Float(i % 3) * 0.05, 0]) }
    let alone = (0..<4).map { i in unit([0.05, 1, 0, Float(i) * 0.02]) }
    let kept = SpeakerMask.dominantVoice(mixed + alone)
    #expect(kept.count == mixed.count, "only the person's windows are kept")
    let center = SpeakerMask.centroid(kept)
    let others = (mixed + alone).filter { SpeakerMask.similarity($0, center) < SpeakerMask.match }
    let print = SpeakerMask.voiceprint(mine: kept, others: others)
    #expect(SpeakerMask.similarity(print, tv) < SpeakerMask.similarity(center, tv), "the TV's direction is taken out")
    #expect(abs(SpeakerMask.similarity(print, tv)) < 0.05)
    #expect(SpeakerMask.similarity(print, person) > 0.9)
    // Nobody else heard: the plain mean.
    #expect(SpeakerMask.voiceprint(mine: kept, others: []) == center)
    #expect(SpeakerMask.dominantVoice([]).isEmpty && SpeakerMask.dominantVoice([person]) == [person])
}
