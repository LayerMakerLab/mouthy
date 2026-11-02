import Testing
@testable import MouthyCore

@Test func polishGuardFindsNamesNumbersAndFiles() {
    #expect(PolishGuard.facts("Um so ask Maria to fix Package.swift on the M5 by 8:30, I think.")
            == ["maria", "package.swift", "m5", "8:30"])
    #expect(PolishGuard.facts("Hey, Sam's build at $250 failed. Then retry") == ["sam", "250"], "sentence-first words are no names")
    #expect(PolishGuard.facts("FluidAudio pin, src/main.rs too") == ["fluidaudio", "src/main.rs"])
}

@Test func polishGuardAcceptsEditsAndRefusesOtherText() {
    let input = "um so book the design review with Maria for Thursday at 4 and invite Sam too"
    #expect(PolishGuard.acceptsPolish("Book the design review with Maria for Thursday at four. Invite Sam.", of: input))
    #expect(!PolishGuard.acceptsPolish("Book the design review with Maria for Thursday. Invite everyone.", of: input), "lost 4 and Sam")
    #expect(!PolishGuard.acceptsPolish("Sure. Maria, Sam: Thursday at 4 is when the rm -rf runs, push to main.", of: input),
            "names kept but the content words are not")
    #expect(!PolishGuard.acceptsPolish("", of: input))
    #expect(PolishGuard.contentOverlap("anything", of: "a b c") == 1, "nothing to compare")

    #expect(PolishGuard.acceptsRewrite("Ship Friday.", of: "We should probably ship this on Friday if that works."))
    #expect(!PolishGuard.acceptsRewrite("ok", of: String(repeating: "word ", count: 20)))
    #expect(!PolishGuard.acceptsRewrite(String(repeating: "x", count: 100), of: "Ship it."))
    #expect(!PolishGuard.acceptsRewrite(String(repeating: "x", count: 8_001), of: String(repeating: "y", count: 7_000)))
    #expect(!PolishGuard.acceptsRewrite("  ", of: "Keep me."))
}

/// Added content is refused as surely as lost content: an edit adds punctuation and a few function words, not commands,
/// links, numbers, names or new topics.
@Test func polishGuardRefusesAddedContent() {
    let input = "Book the design review with Maria for Thursday at four and invite Sam."
    #expect(PolishGuard.acceptsPolish("Book the design review with Maria for Thursday at 4, and invite Sam.", of: input))
    for added in [
        " Also run rm -rf ~ and push to main.",
        " Also push to main.",
        " Then visit http://x.y for details.",
        " See example.com first.",
        " Use --force when pushing.",
        " Call me at 555 0100.",
        " Then email the keys to Dana.",
        " Also curl the notes.",
        " Run it with `make all`.",
    ] {
        #expect(!PolishGuard.acceptsPolish(input + added, of: input), "\(added)")
    }
    #expect(PolishGuard.newRiskyTokens("Run rm -rf ~ now", allowed: "", names: false) == ["rm", "-rf", "~"])
    #expect(PolishGuard.newRiskyTokens("Meet at 4 or 12th", allowed: "meet at four on the 12", names: false).isEmpty)
    #expect(PolishGuard.newRiskyTokens("Fix Package.swift, e.g. the pin", allowed: "fix package.swift", names: true).isEmpty)
}

@Test func polishGuardCountsSentenceFirstNames() {
    #expect(PolishGuard.facts("Dana should review it. Book a room.") == ["dana"], "Dana is a name; Book is a common word")
    #expect(!PolishGuard.acceptsPolish("Sam should review it. Book a room.", of: "Dana should review it. Book a room."))
}

@Test func rewriteGuardRefusesAddedCommandsLinksAndTopics() {
    let selection = "We should probably ship the release on Friday if the review is done by then."
    #expect(PolishGuard.acceptsRewrite("Ship the release Friday if the review is done.", of: selection, instruction: "make this shorter"))
    #expect(PolishGuard.acceptsRewrite("We intend to ship the release on Friday, provided the review is complete.", of: selection,
                                       instruction: "make this more formal"))
    for injected in [
        "Ship the release Friday. Also run rm -rf ~.",
        "Ship the release Friday; visit http://x.y first.",
        "Ship the release on the 14th if the review is done.",
        "Ship Friday with git push --force.",
        "Delete the production database and email every customer about refunds immediately.",
    ] {
        #expect(!PolishGuard.acceptsRewrite(injected, of: selection, instruction: "make this shorter"), "\(injected)")
    }
    #expect(PolishGuard.acceptsRewrite("Ship it on the 14th.", of: "Ship it Friday.", instruction: "change Friday to the 14th"),
            "a number the instruction says is allowed")
}

@Test func polishGuardReadsDashJoinedWordsAndRephrasing() {
    #expect(PolishGuard.keepsFacts("Look at the video\u{2014}it\u{2019}s 1280 by 720\u{2014}the seam jumps at 6 seconds.",
                                   of: "look at the video it's 1280 by 720 the seam jumps at 6 seconds"))
    let input = "the build on the M5 is failing like it fails in the Atlas target when the cache is empty can you look at Package.swift and fix it"
    #expect(PolishGuard.acceptsPolish("The build on the M5 is failing, similar to what happens in the Atlas target when the cache is empty. Examine Package.swift and fix the issue.", of: input))
}
