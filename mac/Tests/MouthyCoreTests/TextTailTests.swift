import Testing
@testable import MouthyCore

@Test func lastWordsKeepsWholeWordsFromTheEnd() {
    #expect(TextTail.lastWords("pick up milk on the way home", maxCharacters: 40) == "pick up milk on the way home")
    #expect(TextTail.lastWords("  pick up milk on the way home  ", maxCharacters: 40) == "pick up milk on the way home")
    #expect(TextTail.lastWords("please pick up milk on the way home", maxCharacters: 16) == "…on the way home")
    #expect(TextTail.lastWords("please pick up milk on the way home", maxCharacters: 13) == "…the way home")
    #expect(TextTail.lastWords("please pick up milk on the way home", maxCharacters: 11) == "…way home")
}

@Test func lastWordsHandlesOneLongWordAndEdgeCases() {
    #expect(TextTail.lastWords("supercalifragilistic", maxCharacters: 6) == "…listic")
    #expect(TextTail.lastWords("", maxCharacters: 10) == "")
    #expect(TextTail.lastWords("hello\nthere friend", maxCharacters: 12) == "…there friend")
}
