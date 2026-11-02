import Foundation
import Testing
@testable import MouthyCore

/// A fixed clock: Tuesday 6 October 2026 in New York, at the given hour.
private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func at(_ hour: Int, _ minute: Int = 0, day: Int = 6) -> Date {
    newYork.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
}

private func parse(_ text: String, now: Date = at(14), requiresName: Bool = false) -> NotchCommand? {
    NotchCommand.parse(text, now: now, calendar: newYork, requiresName: requiresName)
}

@Test(arguments: [
    ("timer 10 minutes", 600),
    ("Timer, 10 minutes.", 600),
    ("set a timer for an hour and a half", 5400),
    ("Set a timer for ten minutes.", 600),
    ("start a 5 minute timer", 300),
    ("Set a 25-minute timer.", 1500),
    ("timer for twenty-five minutes", 1500),
    ("Set a timer for 1 hour 30 minutes.", 5400),
    ("timer 90 seconds", 90),
    ("set a timer for half an hour", 1800),
    ("Timer, two and a half minutes.", 150),
    ("Set a timer for 1.5 hours.", 5400),
    ("timer for an hour and 15 minutes", 4500),
])
func timersParseSpokenDurations(text: String, seconds: Int) {
    #expect(parse(text) == .timer(seconds: seconds))
}

@Test(arguments: [
    ("note call mom", "call mom"),
    ("Note: call Mom.", "call Mom"),
    ("Take a note, buy milk.", "buy milk"),
    ("Note to self: water the plants.", "water the plants"),
])
func notesKeepTheSpokenText(text: String, note: String) {
    #expect(parse(text) == .note(note))
}

@Test func remindersTakeTheSoonestTwelveHourOccurrence() {
    #expect(parse("remind me at 5 to call mom", now: at(14)) == .reminder(due: at(17), text: "call mom"))
    #expect(parse("remind me at 5 to call mom", now: at(18)) == .reminder(due: at(5, day: 7), text: "call mom"))
    #expect(parse("remind me at 11 to stretch", now: at(14)) == .reminder(due: at(23), text: "stretch"))
    #expect(parse("Remind me at five to call Mom.", now: at(14)) == .reminder(due: at(17), text: "call Mom"))
}

@Test func remindersReadClockTimes() {
    #expect(parse("Remind me at 5 PM to call Mom.") == .reminder(due: at(17), text: "call Mom"))
    #expect(parse("remind me at 5:30 to stretch") == .reminder(due: at(17, 30), text: "stretch"))
    #expect(parse("Remind me to call mom at 9 a.m.") == .reminder(due: at(9, day: 7), text: "call mom"))
    #expect(parse("Remind me at 17:45 to leave.") == .reminder(due: at(17, 45), text: "leave"))
    #expect(parse("remind me at noon to eat") == .reminder(due: at(12, day: 7), text: "eat"))
    #expect(parse("Remind me to look at the oven at 6.") == .reminder(due: at(18), text: "look at the oven"))
}

@Test func questionsOnlyFollowTheName() {
    #expect(parse("Mouthy, what's 12 times 12?") == .question("what's 12 times 12?"))
    #expect(parse("Mouthy what is the capital of France") == .question("what is the capital of France"))
    #expect(parse("Mouthy, is it Tuesday?", requiresName: true) == .question("is it Tuesday?"))
    #expect(parse("what's 12 times 12?") == nil)
}

@Test func theNameUnlocksCommandsFromAnyDictation() {
    #expect(parse("Mouthy, note buy milk", requiresName: true) == .note("buy milk"))
    #expect(parse("Mouthy. Set a timer for 10 minutes.", requiresName: true) == .timer(seconds: 600))
    #expect(parse("mouthy, remind me at 5 to call mom", requiresName: true) == .reminder(due: at(17), text: "call mom"))
}

@Test(arguments: [
    ("Note that the build failed.", true),
    ("Remind me why we did this.", true),
    ("I set a timer yesterday.", true),
    ("timer 10 minutes", true),
    ("Mouthy is a great app.", true),
    ("Mouthy,", true),
    ("I set a timer yesterday.", false),
    ("Remind me why we did this.", false),
    ("Set a timer for later.", false),
    ("Notes from the meeting.", false),
    ("Remind me at 25 to stretch.", false),
    ("Note.", false),
    ("Mouthy's going to be great, right?", true),
    ("Mouthy\u{2019}s going to be great, right?", true),
    ("Mouthy-like apps are cool, aren't they?", true),
    ("Mouthy's going to be great, right?", false),
    ("Mouthy\u{2019}s going to be great, right?", false),
    ("Mouthy-like apps are cool, aren't they?", false),
])
func ordinaryDictationIsNeverACommand(text: String, requiresName: Bool) {
    #expect(parse(text, requiresName: requiresName) == nil)
}

/// How speech recognizers write a spoken timer command.
@Test(arguments: [
    "And Mouthy, set a timer for ten minutes.",
    "Hey Mouthy. start a ten-minute timer.",
    "Mouthy. Started ten minute timer",
    "Mouthy start a 10 minute timer.",
    "Mouthie, start a ten-minute timer.",
    "Malty, set a timer for ten minutes.",
    "Okay Mouthy, timer for ten minutes",
    "Matthew, set a timer for 10 minutes.",
])
func misheardNamesAndVerbsStillStartTheTimer(text: String) {
    #expect(parse(text, requiresName: true) == .timer(seconds: 600))
}

@Test func theTimerStopsByVoice() {
    #expect(parse("Mouthy, stop the timer.", requiresName: true) == .stopTimer)
    #expect(parse("Mouthy, cancel timer", requiresName: true) == .stopTimer)
    #expect(parse("Mouthie, stop my timer.", requiresName: true) == .stopTimer)
    #expect(parse("Stop timer.") == .stopTimer)
    #expect(parse("Stop timer.", requiresName: true) == nil)
}

@Test func aCommandForMouthyThatIsNotUnderstoodIsNotText() {
    #expect(parse("Mouthy, set a timer for later.", requiresName: true) == .unrecognized("set a timer for later."))
    #expect(parse("Mouthy, remind me about the thing.", requiresName: true) == .unrecognized("remind me about the thing."))
    // A misheard name never stands for a command that wasn't understood: that is somebody's sentence.
    #expect(parse("Matthew, set the table.", requiresName: true) == nil)
    #expect(parse("Malty, set a timer for later.", requiresName: true) == nil)
    #expect(parse("Mouthy, stop the ten-minute timer for now.", requiresName: true) == .unrecognized("stop the ten-minute timer for now."))
    #expect(parse("Hey Mouthy, cancel my timer please.", requiresName: true) == .unrecognized("cancel my timer please."))
}

@Test func misheardNamesNeverAskQuestionsOrTakeBareNotes() {
    #expect(parse("Matthew, what time is it?", requiresName: true) == nil)
    #expect(parse("Merci, oui", requiresName: true) == nil)
    #expect(parse("Matthew, note that the build failed.", requiresName: true) == nil)
    #expect(parse("Mouthie, take a note, buy milk.", requiresName: true) == .note("buy milk"))
    #expect(parse("Hey Mouthy, what's 12 times 12?", requiresName: true) == .question("what's 12 times 12?"))
}

@Test(arguments: [
    "Mouthy is great, set it up.",
    "Matthew called about the timer.",
    "Malty whisky is nice.",
    "Mouthy is a great timer app.",
    "And Mouthy's notch is nice.",
    "So the timer went off.",
    "Merci beaucoup.",
    // A lead-in only goes with the real name: these are people being addressed.
    "Hi Matthew, make a note that the invoice is due Friday.",
    "Hey Matthew, remind me to send the deck by 5.",
    "So Matthew started a ten-minute timer.",
    "Matthew, started a ten-minute timer.",
    "Matthew started a ten-minute timer.",
    // Talk about Mouthy is typed, not taken as a failed command.
    "Mouthy, timers don't stop at zero.",
    "So Mouthy, stop showing the timer when music plays.",
])
func sentencesThatMentionTheNameStayText(text: String) {
    #expect(parse(text, requiresName: true) == nil)
}
