import Foundation
import Testing
import MouthyCore
@testable import MouthyKit

// MOUTHY_TEST_NATIVE=1 swift test --filter polishKeepsNamesAndNumbers
// Apple's on-device model (Apple Intelligence on) polishes ten spoken briefs, the way a host app sends them
// before an agent prompt. Every name and number must survive, and a corrected value must be the only one left.
// Prints each result and its time; nothing is saved.

private struct Brief {
    let spoken: String
    /// Each entry: words of which at least one must appear (a number may come back as a digit or a word).
    let keep: [[String]]
    /// Words that must be gone (the value a spoken correction replaced).
    var drop: [String] = []
}

private let briefs: [Brief] = [
    Brief(spoken: "um so can you book the design review with Maria for Thursday at three. No, make it four. and invite Sam too",
          keep: [["Maria"], ["Thursday"], ["4", "four"], ["Sam"]], drop: ["three", "3"]),
    Brief(spoken: "okay so the build on the M5 is failing like it fails in the Atlas target when the cache is empty can you look at Package.swift and fix it",
          keep: [["M5"], ["Atlas"], ["Package.swift"]]),
    Brief(spoken: "I need you to bump the FluidAudio pin to 0.17.4 and then uh run the tests again with dash j 3 so the machine stays cool",
          keep: [["FluidAudio"], ["0.17.4"], ["3", "three"]]),
    Brief(spoken: "so basically write a function that takes the 40 latest orders from Etsy and you know groups them by week and then shows the top 5",
          keep: [["40", "forty"], ["Etsy"], ["5", "five"]]),
    Brief(spoken: "hey can you ask Dana whether the invoice for 250 dollars went out on October 12th or was it the 13th I forget",
          keep: [["Dana"], ["250"], ["12", "12th", "twelfth"], ["13", "13th", "thirteenth"]]),
    Brief(spoken: "please rename the Ravel gate script to ravel-gate.py and um make sure Orbit still calls it at 8:30 every weekday",
          keep: [["Ravel"], ["ravel-gate.py"], ["Orbit"], ["8:30"]]),
    Brief(spoken: "look at the backdrop video it's 1280 by 720 and the loop seam jumps at about 6 seconds can you crossfade the last 12 frames",
          keep: [["1280"], ["720"], ["6", "six"], ["12", "twelve"]]),
    Brief(spoken: "add a setting for the minute cap default 10 range 1 to 30 and write the spend line as talk slash provider slash model",
          keep: [["10", "ten"], ["1", "one"], ["30", "thirty"]]),
    Brief(spoken: "tell Otis and Juniper to review branch feat voice strip and um Walter can merge it if Ravel says yes",
          keep: [["Otis"], ["Juniper"], ["Walter"], ["Ravel"]]),
    Brief(spoken: "set the voice limit to 60 seconds. Sorry, make that 90. and keep the Parakeet model on the Neural Engine",
          keep: [["90", "ninety"], ["Parakeet"], ["Neural Engine"]], drop: ["60", "sixty"]),
]

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1"))
func polishKeepsNamesAndNumbers() async throws {
    try #require(DictationPolish.isAvailable, "Apple Intelligence is off on this Mac")
    DictationPolish.prewarm()
    var failures: [String] = []
    var unchanged = 0
    let clock = ContinuousClock()
    for (index, brief) in briefs.enumerated() {
        let began = clock.now
        var raw = ""
        let result = try await DictationPolish.polish(brief.spoken, instructions: DictationPolish.promptInstructions, context: "",
                                                      timeout: DictationPolish.timeout, available: true) { text, instructions, context in
            raw = try await TextEnhancer.edit(text, mode: .custom, customInstructions: instructions, context: context, fenced: true)
            return raw
        }
        let elapsed = clock.now - began
        if result == brief.spoken {
            unchanged += 1
            let prepared = DictationPolish.prepare(brief.spoken)
            Swift.print("POLISH \(index + 1) refused by PolishGuard: \(raw) | facts kept \(PolishGuard.keepsFacts(raw, of: prepared)), overlap "
                        + "\(PolishGuard.contentOverlap(raw, of: prepared)), new tokens \(PolishGuard.newRiskyTokens(raw, allowed: prepared, names: true)), "
                        + "new content \(PolishGuard.newContentShare(raw, vocabulary: prepared))")
        }
        Swift.print("POLISH \(index + 1) \(elapsed.formatted(.units(allowed: [.milliseconds]))): \(result)")
        let words = Set(result.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "." && $0 != ":" && $0 != "-" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        let lower = result.lowercased()
        for options in brief.keep where !options.contains(where: { option in
            option.contains(where: { $0 == " " || $0 == "." || $0 == ":" || $0 == "-" }) ? lower.contains(option.lowercased()) : words.contains(option.lowercased())
        }) {
            failures.append("brief \(index + 1) lost \(options.joined(separator: "/")): \(result)")
        }
        for word in brief.drop where words.contains(word.lowercased()) {
            failures.append("brief \(index + 1) kept the corrected \(word): \(result)")
        }
    }
    Swift.print("POLISH \(briefs.count - unchanged) of \(briefs.count) polished, \(unchanged) kept as spoken")
    #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    #expect(unchanged <= 1, "PolishGuard refused \(unchanged) real polishes")
}

// MOUTHY_TEST_NATIVE=1 swift test --filter rewriteGuardsPassRealRewrites
// Spoken rewrites of a selection by the on-device model must get past PolishGuard (or the person's edit is lost).
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_NATIVE"] == "1"))
func rewriteGuardsPassRealRewrites() async throws {
    try #require(DictationPolish.isAvailable, "Apple Intelligence is off on this Mac")
    let cases: [(selection: String, instruction: String)] = [
        ("We should probably ship the release on Friday if Maria has finished the review by then, otherwise Monday.", "make this shorter"),
        ("hey can u check the build its failing again on the M5 when the cache is empty, thx", "make this more formal"),
        ("Me and Sam has went to the shop and buyed three spools of filament for the order.", "fix the grammar"),
        ("I think the backdrop loop jumps at six seconds and maybe the crossfade is too short so it looks bad.", "make this more direct"),
        ("Please review the pull request for the voice strip, check the tests pass, and then merge it into main.", "make this friendlier"),
    ]
    var rejected: [String] = []
    for (selection, instruction) in cases {
        let result = try await DictationPolish.rewrite(selection: selection, instruction: instruction)
        Swift.print("REWRITE \(instruction): \(result == selection ? "(kept) " : "")\(result)")
        if result == selection { rejected.append(instruction) }
    }
    #expect(rejected.isEmpty, "rewrites kept as they were: \(rejected)")
}
