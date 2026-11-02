import Testing
@testable import MouthyCore

/// "No, make it four": the corrected value replaces the one it corrects, of the same kind, in the same sentence.
@Test func spokenCorrectionKeepsOnlyTheCorrectedValue() {
    #expect(SpokenCorrection.apply("Thursday at three. No, make it four.") == "Thursday at four.")
    #expect(SpokenCorrection.apply("Meet Maria on Thursday at three, no, make it four, in the lab.") == "Meet Maria on Thursday at four, in the lab.")
    #expect(SpokenCorrection.apply("Book two tickets. Sorry, make that three.") == "Book three tickets.")
    #expect(SpokenCorrection.apply("Ship it on Monday, I mean Tuesday.") == "Ship it on Tuesday.")
    #expect(SpokenCorrection.apply("Call at 3:30. No, 4:15.") == "Call at 4:15.")
    #expect(SpokenCorrection.apply("Call at three PM, no, make it four.") == "Call at four PM.")
    #expect(SpokenCorrection.apply("Call at three PM. No, make it ten a.m.") == "Call at ten a.m.")
    #expect(SpokenCorrection.apply("Set the limit to 40. No wait, 50.") == "Set the limit to 50.")
    #expect(SpokenCorrection.apply("Due in March. No, make it April.") == "Due in April.")
    #expect(SpokenCorrection.apply("I'd like two, no, three.") == "I'd like three.", "\"like\" is no reporting verb")
    #expect(SpokenCorrection.apply("Thursday at three. No, make it Friday.") == "Friday at three.", "a day replaces the day, not the time")
    #expect(SpokenCorrection.apply("Version 2.5, no, 2.6 please.") == "Version 2.5, no, 2.6 please.", "the value must end its clause")
    #expect(SpokenCorrection.apply("Version 2.5. No, 2.6.") == "Version 2.6.")
}

@Test func spokenCorrectionLeavesOrdinarySpeechAlone() {
    for text in [
        "No, four is too many.",
        "We need three. No, four is too many.",
        "I mean it.",
        "Make it four columns wide.",
        "Is it Monday? No, it is not.",
        "Ask Sam about the build. No, Maria.",            // a name, not a value: left for the model
        "Use two spaces. No, make it a tab.",
        // Reported speech stays as spoken.
        "Ask for two chairs, she said no, four.",
        "Ask for two chairs, she said, no, four.",
        "Order two pizzas. He told me, make that three.",
        "Bring two boxes, Sam asked, I mean three.",
        "Write two lines: \"Meet at three. No, make it four.\"",
        "Quote him: \u{201C}we need two, no, four\u{201D} and move on.",
        "Book it for three, they replied, no, four.",
        // The correction must open a clause.
        "Book two rooms no four.",
        "Ship Monday I mean Tuesday.",
        "",
    ] {
        #expect(SpokenCorrection.apply(text) == text)
    }
    // Two corrections in one brief.
    #expect(SpokenCorrection.apply("Build two pages on Monday. No, make it Tuesday. Use five colors, sorry, make that six.")
            == "Build two pages on Tuesday. Use six colors.")
}
