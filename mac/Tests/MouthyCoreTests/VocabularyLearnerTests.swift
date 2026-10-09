import Testing
@testable import MouthyCore

private let dictionary: Set<String> = ["the", "meeting", "with", "is", "at", "noon", "send", "it", "to", "corp", "core", "talk", "about", "today", "we", "should", "ship"]
private func known(_ word: String) -> Bool { dictionary.contains(word) }

@Test func learnsCorrectedNames() {
    #expect(VocabularyLearner.corrections(inserted: "The meeting with Anna Carr is at noon.", edited: "The meeting with Anna Kaur is at noon.", isKnownWord: known) == ["Kaur"])
    #expect(VocabularyLearner.corrections(inserted: "Send it to zefir today.", edited: "Send it to Zephyr today.", isKnownWord: known) == ["Zephyr"])
}
@Test func ignoresRewritesAndOrdinaryEdits() {
    #expect(VocabularyLearner.corrections(inserted: "We should ship it today.", edited: "We should ship it tomorrow morning.", isKnownWord: known).isEmpty)
    #expect(VocabularyLearner.corrections(inserted: "We should talk about it today.", edited: "We should talk about the core today.", isKnownWord: known).isEmpty)
    #expect(VocabularyLearner.corrections(inserted: "Ship it.", edited: "Ship it.", isKnownWord: known).isEmpty)
}
@Test func mergeKeepsVocabularyUnique() {
    #expect(VocabularyLearner.merge(["Kaur", "zephyr"], into: "Acme, Zephyr") == "Acme\nZephyr\nKaur")
    #expect(VocabularyLearner.terms("Acme, Zephyr\nNew York\n\n kubectl ") == ["Acme", "Zephyr", "New York", "kubectl"])
}
@Test func learnsNamesThatSoundUnlikeTheirSpelling() {
    let learned = VocabularyLearner.soundAlikes(inserted: "Chavon asked about the meeting today.", edited: "Siobhan asked about the meeting today.", isKnownWord: known)
    #expect(learned.map(\.heard) == ["Chavon"] && learned.map(\.meant) == ["Siobhan"])
    // A real word changed to a name is a decision, not a misrecognition.
    #expect(VocabularyLearner.soundAlikes(inserted: "Send it to the core today.", edited: "Send it to the Bridge today.", isKnownWord: known).isEmpty)
    // Similar spellings are handled as vocabulary hints instead.
    #expect(VocabularyLearner.soundAlikes(inserted: "Send it to zefir today.", edited: "Send it to Zephyr today.", isKnownWord: known).isEmpty)
}
