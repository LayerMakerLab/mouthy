import Testing
import Foundation
@testable import MouthyCore

@Test func syncMergesWithoutLosingAnything() throws {
    var mac = Preferences()
    mac.vocabulary = "Acme, Zephyr"
    mac.replacements = [Replacement(phrase: "my email", replacement: "me@example.com")]
    let shared = DictationMode(name: "Code")
    mac.modes = [shared]
    var other = SyncDocument()
    other.vocabulary = ["zephyr", "Nimbus"]
    other.replacements = [Replacement(phrase: "My Email", replacement: "different"), Replacement(phrase: "sig", replacement: "Thanks, Sam")]
    other.macModes = [shared, DictationMode(name: "Mail")]
    #expect(other.apply(to: &mac))
    #expect(mac.vocabulary == "Acme\nZephyr\nNimbus")
    #expect(mac.replacements.map(\.phrase) == ["my email", "sig"] && mac.replacements[0].replacement == "me@example.com")
    #expect(mac.modes.map(\.name) == ["Code", "Mail"])
    #expect(!other.apply(to: &mac))
    let decoded = try JSONDecoder().decode(SyncDocument.self, from: JSONEncoder().encode(SyncDocument(mac)))
    #expect(decoded == SyncDocument(mac))
}

@Test func syncKeepsWhatWasRemovedHereRemoved() {
    let kept = DictationMode(name: "Code"), dropped = DictationMode(name: "Mail")
    var before = Preferences()
    before.vocabulary = "Acme\nZephyr"
    before.replacements = [Replacement(phrase: "sig", replacement: "Thanks"), Replacement(phrase: "addr", replacement: "1 Main St")]
    before.modes = [kept, dropped]
    var now = before
    now.vocabulary = "Acme"; now.replacements.removeLast(); now.modes = [kept]
    let removed = SyncDocument.Removed(from: before, to: now)
    #expect(removed.words == ["zephyr"] && removed.phrases == ["addr"] && removed.modes == [dropped.id])
    // The shared file still has them, plus something another machine added.
    var shared = SyncDocument(before)
    shared.vocabulary.append("Nimbus")
    #expect(shared.apply(to: &now, removed: removed))
    #expect(now.vocabulary == "Acme\nNimbus")
    #expect(now.replacements.map(\.phrase) == ["sig"])
    #expect(now.modes.map(\.name) == ["Code"])
}
