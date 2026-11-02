import Testing
@testable import MouthyCore

@Test func vocabularySwapsThatOnlyAddLettersAreRefused() {
    #expect(!VocabularyGuard.keeps(original: "code", term: "Codex"))
    #expect(!VocabularyGuard.keeps(original: "blend", term: "Blender"))
    #expect(VocabularyGuard.keeps(original: "cloud", term: "Claude"))
    #expect(VocabularyGuard.keeps(original: "get hub", term: "GitHub"))
    #expect(VocabularyGuard.keeps(original: "codecs", term: "Codex"))
    // The refused swap goes, the rest of the pass stays, in order.
    #expect(VocabularyGuard.apply("Ask cloud to review the code before codecs merges it.",
                                  swaps: [(original: "code", term: "Codex"), (original: "cloud", term: "Claude"), (original: "codecs", term: "Codex")])
            == "Ask Claude to review the code before Codex merges it.")
    #expect(VocabularyGuard.apply("Push it to get hub, please.", swaps: [(original: "get hub", term: "GitHub")]) == "Push it to GitHub, please.")
    // A span that is not there: keep the text without the pass rather than guess.
    #expect(VocabularyGuard.apply("Nothing here.", swaps: [(original: "cloud", term: "Claude")]) == nil)
}

@Test func namesHeardMidSentenceBecomeTheTermSpelledLikeThem() {
    let terms = ["Claude", "Codex", "Grak", "Opus", "Mochi"]
    let known: (String) -> Bool = { ["cloud", "the", "ask", "code", "mark", "grow"].contains($0) }
    #expect(VocabularyGuard.names("Ask Cloud to review it.", terms: terms, isKnownWord: known) == "Ask Claude to review it.")
    #expect(VocabularyGuard.names("Open Cloud Code, then run it.", terms: terms, isKnownWord: known) == "Open Claude Code, then run it.")
    // Ordinary words, sentence starts and real names stay.
    #expect(VocabularyGuard.names("It lives in the cloud.", terms: terms, isKnownWord: known) == "It lives in the cloud.")
    #expect(VocabularyGuard.names("Done. Cloud storage is full.", terms: terms, isKnownWord: known) == "Done. Cloud storage is full.")
    #expect(VocabularyGuard.names("Ask Greg to review it.", terms: terms, isKnownWord: known) == "Ask Greg to review it.")
    #expect(VocabularyGuard.names("Ask Mark to review it.", terms: terms, isKnownWord: known) == "Ask Mark to review it.")
}

/// The vocabulary pass swaps a span as long as the term in words; only the words that sound like the term change.
@Test func vocabularySwapsKeepNeighbouringWords() {
    #expect(VocabularyGuard.trimmed("Ask XGrower", to: "X Grower") == "XGrower")
    #expect(VocabularyGuard.trimmed("get hub", to: "GitHub") == "get hub")
    #expect(VocabularyGuard.trimmed("Sales force", to: "Salesforce") == "Sales force")
    #expect(VocabularyGuard.apply("Ask XGrower to post the thread today.", swaps: [(original: "Ask XGrower", term: "X Grower")])
            == "Ask X Grower to post the thread today.")
    #expect(VocabularyGuard.apply("Push it to get hub.", swaps: [(original: "get hub", term: "GitHub")]) == "Push it to GitHub.")
}

/// A multi-word term written as one word comes back as the term; only an exact letter match counts.
@Test func runTogetherTermsAreSpacedLikeTheTerm() {
    #expect(VocabularyGuard.spacing("Then check what XGrower found.", terms: ["X Grower", "Grak"]) == "Then check what X Grower found.")
    #expect(VocabularyGuard.spacing("xgrower, again", terms: ["X Grower"]) == "X Grower, again")
    #expect(VocabularyGuard.spacing("Let's explore it. Xcrower too.", terms: ["X Grower"]) == "Let's explore it. Xcrower too.")
    // One letter off counts only for words the dictionary does not know.
    let known: Set<String> = ["explore", "grower"]
    #expect(VocabularyGuard.spacing("Let's explore it. Xcrower too.", terms: ["X Grower"], isKnownWord: known.contains)
            == "Let's explore it. X Grower too.")
}
