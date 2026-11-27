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

@Test func aDictationScoreCountsTheWordsThePersonChanged() {
    // Capitals and the marks around a word are not a changed word; another word is, and so is one added or removed.
    #expect(DictationScore.changedWords(inserted: "Put their bags over there.", within: "put their bags, over there") == 0)
    #expect(DictationScore.changedWords(inserted: "Put there bags over their", within: "Put their bags over there") == 2)
    #expect(DictationScore.changedWords(inserted: "two rows two for the peas", within: "two rows too for the green peas") == 2)
    #expect(DictationScore.changedWords(inserted: "send it to the team today", within: "send it today") == 3)
    #expect(DictationScore.changedWords(inserted: "", within: "") == 0 && DictationScore.changedWords(inserted: "hello there", within: "") == 2)
    // The field is read from where the text went in, a little past its end: words around it are not the dictation's.
    // An edit in front of it shifts the read ("Sam" made "Samuel"), and a deleted word lets the next sentence in.
    #expect(DictationScore.changedWords(inserted: "We meet on Monday.", within: "el. We meet on Monday. Then lunch") == 0)
    #expect(DictationScore.changedWords(inserted: "We meet on Monday.", within: "We meet Monday. Then we have lunch") == 1)
    #expect(DictationScore.changedWords(inserted: "We meet on Monday.", within: "They meet on Monday. Then lunch") == 1)
}

@Test func dictationScoresAddUpByDay() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    func score(_ day: Int, words: Int, typed: Int?, back: Int?, corrected: Int?) -> DictationScore {
        var score = DictationScore(seconds: 10, words: words, typed: typed, tookBack: back, tookBackAtStop: typed == nil ? nil : 0, delivery: "Inserted")
        score.date = Date(timeIntervalSince1970: Double(day) * 86_400 + 3_600)
        score.corrected = corrected
        return score
    }
    let days = DictationScore.days([score(1, words: 100, typed: 500, back: 50, corrected: 2), score(1, words: 50, typed: nil, back: nil, corrected: nil),
                                    score(2, words: 200, typed: 1_000, back: 40, corrected: 1)], calendar: calendar)
    #expect(days.count == 2 && days[0].dictations == 2 && days[0].words == 150)
    // Taken back in percent of what was typed live; corrections per hundred words of the dictations that were watched.
    #expect(days[0].tookBackPercent == 10 && days[0].correctedPerHundred == 2)
    #expect(days[1].tookBackPercent == 4 && days[1].correctedPerHundred == 0.5)
    #expect(DictationScore.days([score(3, words: 10, typed: nil, back: nil, corrected: nil)], calendar: calendar)[0].tookBackPercent == nil)
    // What is saved holds no words: numbers, a date and how the text was delivered.
    let saved = String(decoding: try JSONEncoder().encode(score(1, words: 3, typed: 9, back: 0, corrected: 0)), as: UTF8.self)
    #expect(try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any] != nil)
    #expect(Set((try JSONSerialization.jsonObject(with: Data(saved.utf8)) as! [String: Any]).keys)
            == ["id", "date", "seconds", "words", "typed", "tookBack", "tookBackAtStop", "delivery", "corrected"])
}
