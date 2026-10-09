import Testing
import Foundation
@testable import MouthyCore

@Test func replacementRespectsBoundariesAndLiteralSymbols() {
    let rules = [Replacement(phrase: "swift", replacement: "$1\\Code")]
    #expect(TextPipeline.process("Swift is not swiftly", replacements: rules, punctuation: false) == "$1\\Code is not swiftly")
}
@Test func longestReplacementWinsWithoutCascading() {
    let rules = [Replacement(phrase: "new", replacement: "X"), Replacement(phrase: "new york", replacement: "NewYork"), Replacement(phrase: "NewYork", replacement: "wrong")]
    #expect(TextPipeline.process("new york new", replacements: rules, punctuation: false) == "NewYork X")
}
@Test func unicodeAndNewlines() {
    #expect(TextPipeline.process("Café new paragraph hello", replacements: [Replacement(phrase: "café", replacement: "Cafe")], punctuation: true) == "Cafe\n\nHello")
}
@Test func emptyRulesCannotMatchEverything() {
    #expect(TextPipeline.process(" hello ", replacements: [Replacement(phrase: "", replacement: "bad")], punctuation: false) == "hello")
}
@Test func transcriptFinalizationDoesNotDuplicatePartialText() {
    var accumulator = TranscriptAccumulator()
    accumulator.accept("Hel", isFinal: false)
    accumulator.accept("Hello", isFinal: false)
    accumulator.accept("Hello world.", isFinal: true)
    accumulator.accept("Second", isFinal: false)
    #expect(accumulator.finalText == "Hello world.")
    accumulator.accept("Second sentence.", isFinal: true)
    #expect(accumulator.finalText == "Hello world. Second sentence.")
    #expect(accumulator.preview == accumulator.finalText)
}
@Test func insertionRefusesOnlyNonTextAndPasswordTargets() {
    #expect(DeliveryPolicy.refusal(role: "AXTextArea", subrole: nil, secureInput: false) == nil)
    #expect(DeliveryPolicy.refusal(role: "AXGroup", subrole: nil, secureInput: false) == nil)
    #expect(DeliveryPolicy.refusal(role: nil, subrole: nil, secureInput: false) == nil)
    #expect(DeliveryPolicy.refusal(role: "AXButton", subrole: nil, secureInput: false) != nil)
    #expect(DeliveryPolicy.refusal(role: "AXTextField", subrole: "AXSecureTextField", secureInput: false) != nil)
    #expect(DeliveryPolicy.refusal(role: "AXTextArea", subrole: nil, secureInput: true) != nil)
}
@Test func settingsRoundTrip() throws {
    var original = Preferences()
    original.modes = [DictationMode(name: "Mail")]
    original.replacements = [Replacement(phrase: "new york", replacement: "New York")]
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(original))
    #expect(restored.modes == original.modes)
    #expect(restored.replacements == original.replacements)
    #expect(!restored.keepHistory)
}

@Test func oldSettingsMigrateWithSafeDefaults() throws {
    let data = Data("{\"locale\":\"fr-FR\",\"historyLimit\":9000}".utf8)
    let preferences = try JSONDecoder().decode(Preferences.self, from: data)
    #expect(preferences.locale == "fr-FR")
    #expect(preferences.historyLimit == 1000)
    #expect(!preferences.keepHistory)
    #expect(!preferences.rewriteSelection)
}
