import Testing
import Foundation
@testable import MouthyCore

// shared/text-rules.json is shared with the Windows/Linux core (windows-linux/core) so all platforms behave alike.
private let fixtures: [String: Any] = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("../shared/text-rules.json")
    return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any] ?? [:]
}()
private func cases(_ key: String) -> [[String: Any]] { fixtures[key] as? [[String: Any]] ?? [] }

@Test func sharedFixturesLoad() { #expect(!cases("smartInsertion").isEmpty && !cases("process").isEmpty) }
@Test func sharedSmartInsertion() {
    for c in cases("smartInsertion") {
        #expect(SmartInsertion.adjust(c["text"] as! String, before: c["before"] as! String, after: c["after"] as! String) == c["expected"] as! String)
    }
}
@Test func sharedBacktrackAndPunctuation() {
    for c in cases("backtrack") { #expect(Backtrack.apply(c["text"] as! String) == c["expected"] as! String) }
    for c in cases("spokenPunctuation") { #expect(SpokenPunctuation.apply(c["text"] as! String) == c["expected"] as! String) }
}
@Test func sharedProcess() {
    for c in cases("process") {
        let rules = (c["replacements"] as! [[String: String]]).map { Replacement(phrase: $0["phrase"]!, replacement: $0["replacement"]!) }
        #expect(TextPipeline.process(c["text"] as! String, replacements: rules, punctuation: c["punctuation"] as! Bool) == c["expected"] as! String)
    }
}
@Test func sharedFillers() {
    for c in cases("fillers") { #expect(Fillers.remove(removeHesitationDots(c["text"] as! String)) == c["expected"] as! String) }
}
@Test func sharedCode() {
    for c in cases("code") { #expect(CodeDictation.apply(c["text"] as! String) == c["expected"] as! String) }
}
@Test func sharedTriggers() {
    for c in cases("trigger") {
        let modes = (c["triggers"] as! [String]).map { word -> DictationMode in var m = DictationMode(name: word); m.triggerWord = word; return m }
        let found = ModeResolver.trigger(in: c["text"] as! String, modes: modes)
        #expect(found?.0.name == c["mode"] as? String)
        #expect(found?.1 == c["expected"] as? String)
    }
}
