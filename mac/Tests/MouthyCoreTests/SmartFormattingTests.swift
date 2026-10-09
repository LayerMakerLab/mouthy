import Testing
import Foundation
@testable import MouthyCore

@Test func emptyFieldCapitalizesWithoutPadding() {
    #expect(SmartInsertion.adjust("hello there.", before: "", after: "") == "Hello there.")
}
@Test func afterSentenceAddsSpaceAndCapital() {
    #expect(SmartInsertion.adjust("next idea.", before: "First point.", after: "") == " Next idea.")
    #expect(SmartInsertion.adjust("next idea.", before: "First point. ", after: "") == "Next idea.")
    #expect(SmartInsertion.adjust("next idea.", before: "Line\n", after: "") == "Next idea.")
}
@Test func midSentenceLowercasesAndDropsPeriod() {
    #expect(SmartInsertion.adjust("Really big.", before: "The cat", after: " sat down.") == " really big")
    #expect(SmartInsertion.adjust("Really big.", before: "The cat ", after: "sat down.") == "really big ")
}
@Test func midSentenceKeepsNamesPronounsAndAcronyms() {
    #expect(SmartInsertion.adjust("I think so.", before: "Well,", after: "") == " I think so.")
    #expect(SmartInsertion.adjust("NASA called.", before: "Then", after: "") == " NASA called.")
    #expect(SmartInsertion.adjust("Tuesday works.", before: "Maybe", after: "") == " Tuesday works.")
    #expect(SmartInsertion.adjust("iPhone notes.", before: "My", after: "") == " iPhone notes.")
}
@Test func openersAndClosersAreRespected() {
    #expect(SmartInsertion.adjust("Inside.", before: "(", after: ")") == "Inside")
    #expect(SmartInsertion.adjust("Done.", before: "Almost", after: ".") == " done")
}
@Test func backtrackRemovesPreviousSentence() {
    #expect(Backtrack.apply("Buy milk. Buy eggs scratch that. Buy bread.") == "Buy milk. Buy bread.")
    #expect(Backtrack.apply("Buy eggs, scratch that") == "")
    #expect(Backtrack.apply("Hello there. delete that") == "")
    #expect(Backtrack.apply("Scratch the surface.") == "Scratch the surface.")
}
@Test func pipelineAppliesBacktrackWithSpokenCommandsOnly() {
    #expect(TextPipeline.process("One. Two scratch that", replacements: [], punctuation: true) == "One.")
    #expect(TextPipeline.process("One. Two scratch that", replacements: [], punctuation: false) == "One. Two scratch that")
}
@Test func newPreferencesDecodeFromOlderSettings() throws {
    let decoded = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
    #expect(decoded.smartFormatting && decoded.mediaWhileDictating == .nothing && !decoded.playSounds)
}
