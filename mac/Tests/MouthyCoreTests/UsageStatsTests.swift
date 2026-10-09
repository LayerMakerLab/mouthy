import Testing
import Foundation
@testable import MouthyCore

@Test func statsCountWordsSpeedAndTimeSaved() throws {
    var stats = UsageStats()
    stats.record(text: "one two three four five six", seconds: 2)
    stats.record(text: "   ", seconds: 9)
    #expect(stats.words == 6 && stats.sessions == 1 && stats.wordsPerMinute == 180)
    for _ in 0..<100 { stats.record(text: Array(repeating: "word", count: 40).joined(separator: " "), seconds: 15) }
    #expect(stats.minutesSaved > 70)
    let decoded = try JSONDecoder().decode(UsageStats.self, from: JSONEncoder().encode(stats))
    #expect(decoded == stats)
}
@Test func keyboardLanguagePicksSpeechLocale() {
    let available = ["en-GB", "en-US", "es-ES", "es-MX", "fr-FR", "pt-BR", "pt-PT"]
    #expect(LocaleMatcher.best(language: "es", region: "MX", available: available, fallback: "en-US") == "es-MX")
    #expect(LocaleMatcher.best(language: "es", region: "US", available: available, fallback: "en-US") == "es-ES")
    #expect(LocaleMatcher.best(language: "pt-PT", region: "US", available: available, fallback: "en-US") == "pt-PT")
    #expect(LocaleMatcher.best(language: "en", region: "US", available: available, fallback: "en-US") == "en-US")
    #expect(LocaleMatcher.best(language: "ko", region: "US", available: available, fallback: "en-US") == "en-US")
}
