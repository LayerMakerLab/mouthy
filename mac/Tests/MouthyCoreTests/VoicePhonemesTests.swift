import Foundation
import Testing
@testable import MouthyCore

/// Mouthy's phonemizer against misaki (the G2P the voice was trained with) on 457 sentences: agent-style questions,
/// conversational lines and book lines (`voice-phonemes.json`, made by misaki 0.9.4 with spaCy en_core_web_sm and no
/// espeak; `❓` marks words misaki doesn't know, which Mouthy spells out instead).
@Suite struct VoicePhonemesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let phonemizer = try! VoicePhonemes(lexicon: root.appendingPathComponent("../../Resources/Voice/lexicon.tsv"))
    struct Fixture: Decodable { let text: String; let phonemes: String }
    static let fixtures = try! JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("voice-phonemes.json")))

    @Test func agreesWithMisakiOnMostWords() {
        var same = 0, words = 0, exact = 0, compared = 0
        var misses: [String] = []
        for f in Self.fixtures where !f.phonemes.contains("❓") {
            compared += 1
            let ours = Self.phonemizer.phonemes(f.text)
            if ours == f.phonemes { exact += 1 }
            let a = ours.split(separator: " "), b = f.phonemes.split(separator: " ")
            words += b.count
            if a.count == b.count { same += zip(a, b).filter { $0 == $1 }.count }
            else { same += Set(a).intersection(b).count }
            if ours != f.phonemes, misses.count < 25 { misses.append("\(f.text)\n   misaki: \(f.phonemes)\n   mouthy: \(ours)") }
        }
        let wordRate = Double(same) / Double(words)
        print("VOICE PHONEMES \(exact)/\(compared) sentences exact, \(same)/\(words) words (\(Int(wordRate * 1000)) per mille)")
        for m in misses { print(m) }
        #expect(wordRate > 0.98)
    }

    @Test func numbersAndCleanUp() {
        let p = Self.phonemizer
        #expect(p.phonemes("Mouthy") == "mˈWθi")
        #expect(VoicePhonemes.clean("at 9:30") == "at nine thirty")
        #expect(VoicePhonemes.clean("at 9:05") == "at nine oh five")
        #expect(VoicePhonemes.clean("edit AGENTS.md now") == "edit AGENTS dot M D now")
        #expect(VoicePhonemes.yearWords(2026) == "twenty twenty-six")
        #expect(VoicePhonemes.yearWords(1905) == "nineteen oh-five")
        #expect(VoicePhonemes.yearWords(2009) == "two thousand and nine")
        #expect(VoicePhonemes.ordinalWords(23) == "twenty-third")
        #expect(VoicePhonemes.numberWords(1572) == "one thousand, five hundred and seventy-two")
        #expect(!p.phonemes("The GPU is at 31°C.").isEmpty)
    }
}

extension VoicePhonemesTests {
    @Test func sentenceEndsAreNotAbbreviations() {
        #expect(Self.phonemizer.phonemes("Oh no. Are you okay?") == "ˈO nˈO. ˌɑɹ ju ˌOkˈA?")
        #expect(Self.phonemizer.phonemes("Ask Mr. Smith.").hasPrefix("ˈæsk mˈɪstəɹ "))
    }
}

extension VoicePhonemesTests {
    @Test func hugeNumbersAreReadAsDigits() {
        let ps = Self.phonemizer.phonemes("9223372036854775808")
        #expect(ps.split(separator: " ").count == 19)
        #expect(Self.phonemizer.phonemes("$9223372036854775808.50").contains("nˈIn"))
    }

    @Test func longRunsWithoutSpacesStayFast() {
        let start = Date()
        let ps = Self.phonemizer.phonemes(Array(repeating: "ab", count: 600).joined(separator: "/") + " " + String(repeating: "x", count: 500))
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(!ps.isEmpty)
    }
}
