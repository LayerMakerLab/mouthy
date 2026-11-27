import Foundation

/// One dictation in numbers, so what works and what fails can be read back later without anyone watching: how much
/// "Type as I speak" typed and took back, how the words reached the app, and how many of them the person changed
/// afterwards. No words are stored, here or in the log. Kept on this Mac in `scores.json` (the newest `limit`).
public struct DictationScore: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date = Date()
    /// Speaking time.
    public var seconds: Double
    /// Words delivered.
    public var words: Int
    /// "Type as I speak": characters typed, and taken back while speaking and at the stop. Nil when it was off or
    /// nothing was typed live.
    public var typed: Int?
    public var tookBack: Int?
    public var tookBackAtStop: Int?
    /// How the words reached the app, as the status says it: "Inserted", "Typed", "Pasted" or "Sent".
    public var delivery: String
    /// Words the person changed in the field within a minute. Nil when the field was never watched (it could not be
    /// read, or learning from corrections is off).
    public var corrected: Int?

    public init(seconds: Double, words: Int, typed: Int? = nil, tookBack: Int? = nil, tookBackAtStop: Int? = nil, delivery: String) {
        self.seconds = seconds; self.words = words; self.typed = typed; self.tookBack = tookBack
        self.tookBackAtStop = tookBackAtStop; self.delivery = delivery
    }

    public static let limit = 1_000

    /// How many of the inserted words read differently now: the fewest words changed, added or removed between
    /// `inserted` and any stretch of `region` (the field's text around where it went in), so words before or after
    /// it that are not the dictation's ("el." left over from a name the person edited in front, the next sentence
    /// after a word they deleted) are not counted. Capitals and the marks around a word do not count; a changed word
    /// does ("their" for "there").
    public static func changedWords(inserted: String, within region: String) -> Int {
        func words(_ text: String) -> [String] { text.split(whereSeparator: \.isWhitespace).map(LiveTyping.written) }
        let old = words(inserted), new = words(region)
        // Edit distance to every stretch of `new`: starting anywhere costs nothing, and so does ending anywhere.
        var row = Array(repeating: 0, count: new.count + 1)
        for (i, word) in old.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for j in 0..<new.count {
                let above = row[j + 1]
                row[j + 1] = min(diagonal + (word == new[j] ? 0 : 1), above + 1, row[j] + 1)
                diagonal = above
            }
        }
        return row.min() ?? 0
    }

    /// The scores of one day, added up: the ups and downs are these, day against day.
    public struct Day: Equatable, Sendable {
        public var day: Date
        public var dictations = 0, words = 0
        public var typed = 0, tookBack = 0, tookBackAtStop = 0
        /// Dictations whose field was watched, their words, and how many of those the person changed.
        public var watched = 0, watchedWords = 0, corrected = 0
        /// Taken back while speaking, in percent of what was typed (nil: nothing typed live that day).
        public var tookBackPercent: Double? { typed > 0 ? Double(tookBack) / Double(typed) * 100 : nil }
        /// Words the person changed per hundred delivered (nil: no field was watched that day).
        public var correctedPerHundred: Double? { watchedWords > 0 ? Double(corrected) / Double(watchedWords) * 100 : nil }
    }

    public static func days(_ scores: [DictationScore], calendar: Calendar = .current) -> [Day] {
        var days: [Date: Day] = [:]
        for score in scores {
            let start = calendar.startOfDay(for: score.date)
            var day = days[start] ?? Day(day: start)
            day.dictations += 1; day.words += score.words
            day.typed += score.typed ?? 0; day.tookBack += score.tookBack ?? 0; day.tookBackAtStop += score.tookBackAtStop ?? 0
            if let corrected = score.corrected { day.watched += 1; day.watchedWords += score.words; day.corrected += corrected }
            days[start] = day
        }
        return days.values.sorted { $0.day < $1.day }
    }
}
