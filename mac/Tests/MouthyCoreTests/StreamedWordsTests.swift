import Testing
@testable import MouthyCore

@Test func streamedWordsAreBuiltFromPiecesWithTheTimeOfTheFirst() {
    let words = StreamedWords.words(pieces: ["▁ok", "ay", "▁so", "▁the", "▁set", "t", "ings"], milliseconds: [640, 880, 1000, 1200, 3120, 3200, 3280])
    #expect(words == [StreamedWord("okay", at: 10_240), StreamedWord("so", at: 16_000), StreamedWord("the", at: 19_200), StreamedWord("settings", at: 49_920)])
    // A piece that starts no word joins the one before it; a marker piece is no word.
    #expect(StreamedWords.words(pieces: ["ok", "ay", "<EOU>", "▁so"], milliseconds: [0, 80, 160, 400]).map(\.text) == ["okay", "so"])
    #expect(StreamedWords.words(pieces: [], milliseconds: []).isEmpty)
}

@Test func streamedWordsAfterAPassAreTheOnesSaidAfterItsLastSound() {
    let words = [StreamedWord("still", at: 115_000), StreamedWord("works", at: 120_300), StreamedWord("after", at: 130_500), StreamedWord("that", at: 133_000)]
    // The pass heard sound until sample 125,000: "works" began before it, "after" a pause later.
    #expect(StreamedWords.after(125_000, in: words).map(\.text) == ["after", "that"])
    // A word whose first piece is heard within a tenth of a second of the pass's last sound is still the pass's.
    #expect(StreamedWords.after(120_000, in: words).map(\.text) == ["after", "that"])
    #expect(StreamedWords.after(140_000, in: words).isEmpty)
    #expect(StreamedWords.after(nil, in: words).count == 4)
}

@Test func streamedWordsShowWithTheCapitalsThatAreKnown() {
    let words = ["i", "think", "i'm", "using", "mouthy", "in", "xcode"].map { StreamedWord($0, at: 0) }
    #expect(StreamedWords.written(words, spellings: ["mouthy": "Mouthy", "xcode": "Xcode"]) == "I think I'm using Mouthy in Xcode")
    #expect(StreamedWords.written([StreamedWord("in", at: 0), StreamedWord("it", at: 0)]) == "in it")
}

@Test func streamedWordsThatAreNotWhatThePassHeardMeanAnotherLanguage() {
    func streamed(_ text: String) -> [StreamedWord] { text.split(separator: " ").map { StreamedWord(String($0), at: 0) } }
    // English, with the mistakes the streaming recognizer makes: most words are the pass's.
    #expect(StreamedWords.agrees(streamed("after that pick up old milk and the good bread"), with: "After that, pick up oat milk and the good bread."))
    // German heard as English-sounding words: almost none are.
    #expect(!StreamedWords.agrees(streamed("the nex the tack is t a see the fen stir"), with: "Der nächste Tag ist dazu da, die Fenster zu putzen."))
    // Nothing heard at all where the pass heard a sentence.
    #expect(!StreamedWords.agrees([], with: "Der nächste Tag ist dazu da, die Fenster."))
    // Too few words to tell, and numbers a pass writes as digits, never switch it off.
    #expect(StreamedWords.agrees(streamed("yes"), with: "Ja, genau."))
    #expect(StreamedWords.agrees(streamed("one two three four five six seven eight"), with: "1, 2, 3, 4, 5, 6, 7, 8."))
}
