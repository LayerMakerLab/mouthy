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
    #expect(VocabularyGuard.spelling("Then check what XGrower found.", terms: ["X Grower", "Grak"]) == "Then check what X Grower found.")
    #expect(VocabularyGuard.spelling("xgrower, again", terms: ["X Grower"]) == "X Grower, again")
    #expect(VocabularyGuard.spelling("Let's explore it. Xcrower too.", terms: ["X Grower"]) == "Let's explore it. Xcrower too.")
    // One letter off counts only for words the dictionary does not know.
    let known: Set<String> = ["explore", "grower"]
    #expect(VocabularyGuard.spelling("Let's explore it. Xcrower too.", terms: ["X Grower"], isKnownWord: known.contains)
            == "Let's explore it. X Grower too.")
}

@Test func spellingWritesTermsAsThePersonSpellsThem() {
    let terms = ["Mouthy", "Omarko", "Ollama", "Pixfield", "MakerWorld", "WireGuard", "Claude", "Codex", "X Grower"]
    let known: (String) -> Bool = { ["the", "model", "cloud", "field", "for", "video", "over", "connect", "to", "runs", "mousey",
                                     "messy", "mushy", "local", "upload", "and", "on", "it", "typed", "squad", "claw", "clawed",
                                     "code", "codex", "maker", "world", "wire", "guard", "cat", "couch", "new", "pane"].contains($0) }
    func spelled(_ text: String) -> String { VocabularyGuard.spelling(text, terms: terms, isKnownWord: known) }
    // Same letters, other case or spacing.
    #expect(spelled("Upload the model to Makerworld.") == "Upload the model to MakerWorld.")
    #expect(spelled("Connect over wire guard, then") == "Connect over WireGuard, then")
    #expect(spelled("start a new codex pane") == "start a new codex pane")
    #expect(spelled("Connect over wireguard.") == "Connect over WireGuard.")
    #expect(spelled("Upload it to maker world.") == "Upload it to MakerWorld.")
    // Sounds like a term and is no word.
    #expect(spelled("Alama runs the local model.") == "Ollama runs the local model.")
    #expect(spelled("Connect to a marky over WireGuard") == "Connect to Omarko over WireGuard")
    #expect(spelled("Connect to Amarky.") == "Connect to Omarko.")
    #expect(spelled("Use X field for the video.") == "Use Pixfield for the video.")
    #expect(spelled("Mouthie typed it.") == "Mouthy typed it.")
    // Real words stay, whatever they sound like.
    #expect(spelled("The model is in the cloud.") == "The model is in the cloud.")
    #expect(spelled("The cat clawed the couch.") == "The cat clawed the couch.")
    #expect(spelled("Mousey typed it, messy and mushy.") == "Mousey typed it, messy and mushy.")
    #expect(spelled("Open the squad.") == "Open the squad.")
    // Names the dictionary knows, and ordinary words that spell a term, stay.
    let names: (String) -> Bool = { known($0) || ["Jeff", "Clyde", "Brooke"].contains($0) }
    #expect(VocabularyGuard.spelling("Ask Jeff to call Clyde and Brooke.", terms: ["Jefe", "Claude", "Brooky"], isKnownWord: names)
            == "Ask Jeff to call Clyde and Brooke.")
    #expect(VocabularyGuard.spelling("The blue sky over the cursor.", terms: ["Bluesky", "Cursor"],
                                     isKnownWord: { ["the", "blue", "sky", "over", "cursor"].contains($0) })
            == "The blue sky over the cursor.")
    // Never across punctuation, and nothing without terms.
    #expect(spelled("It's the maker. World peace.") == "It's the maker. World peace.")
    #expect(VocabularyGuard.spelling("Alama runs.", terms: [], isKnownWord: known) == "Alama runs.")
}

@Test func soundKeysWriteOneSoundAlike() {
    #expect(VocabularyGuard.soundKey("Ollama") == VocabularyGuard.soundKey("Alama"))
    #expect(VocabularyGuard.soundKey("Omarko") == VocabularyGuard.soundKey("amarky"))
    #expect(VocabularyGuard.soundKey("Pixfield") == "pksflt" && VocabularyGuard.soundKey("xfield") == "ksflt")
    #expect(VocabularyGuard.soundKey("Mouthy") == VocabularyGuard.soundKey("Mowdy"))
    #expect(VocabularyGuard.soundKey("Claude") != VocabularyGuard.soundKey("Codex"))
}
