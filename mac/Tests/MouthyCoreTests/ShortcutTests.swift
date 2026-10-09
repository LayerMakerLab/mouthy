import Testing
import Foundation
@testable import MouthyCore

@Test func rightCommandRequiresTwoShortUninterruptedTaps() {
    var detector = DoubleTapShortcut()
    let event1 = detector.update(isDown: true, timestamp: 1)
    #expect(event1 == false)
    let event2 = detector.update(isDown: false, timestamp: 1.1)
    #expect(event2 == false)
    let event3 = detector.update(isDown: true, timestamp: 1.2)
    #expect(event3 == false)
    let event4 = detector.update(isDown: false, timestamp: 1.3)
    #expect(event4 == true)
    let event5 = detector.update(isDown: false, timestamp: 1.31)
    #expect(event5 == false)
    let event6 = detector.update(isDown: true, timestamp: 2)
    #expect(event6 == false)
    detector.reset() // Another key was used with Command.
    let event7 = detector.update(isDown: false, timestamp: 2.1)
    #expect(event7 == false)
    let event8 = detector.update(isDown: true, timestamp: 2.2)
    #expect(event8 == false)
    let event9 = detector.update(isDown: false, timestamp: 2.3)
    #expect(event9 == false)
}
@Test func slowAndHeldCommandDoNotTriggerDictation() {
    var detector = DoubleTapShortcut()
    let event10 = detector.update(isDown: true, timestamp: 0)
    #expect(event10 == false)
    let event11 = detector.update(isDown: false, timestamp: 0.1)
    #expect(event11 == false)
    let event12 = detector.update(isDown: true, timestamp: 1)
    #expect(event12 == false)
    let event13 = detector.update(isDown: false, timestamp: 1.1)
    #expect(event13 == false)
    let event14 = detector.update(isDown: true, timestamp: 1.2)
    #expect(event14 == false)
    let event15 = detector.update(isDown: false, timestamp: 1.8)
    #expect(event15 == false)
}
@Test func secondCommandTapCanFinishAfterTheInterTapWindow() {
    var detector = DoubleTapShortcut()
    let result1 = detector.update(isDown: true, timestamp: 1)
    #expect(result1 == false)
    let result2 = detector.update(isDown: false, timestamp: 1.1)
    #expect(result2 == false)
    let result3 = detector.update(isDown: true, timestamp: 1.45)
    #expect(result3 == false)
    let result4 = detector.update(isDown: false, timestamp: 1.65)
    #expect(result4 == true)
    // Completing a pair consumes it; the next tap cannot trigger a third time.
    let result5 = detector.update(isDown: true, timestamp: 1.7)
    #expect(result5 == false)
    let result6 = detector.update(isDown: false, timestamp: 1.8)
    #expect(result6 == false)
}
@Test func physicalAndAggregateOnlyRightCommandEventsBothTrigger() {
    for commandFlags: UInt in [0x100010, 0x100000, 0x10] {
        var detector = DoubleTapShortcut()
        let result7 = detector.update(keyCode: 54, modifierFlags: commandFlags, isModifierEvent: true, timestamp: 1)
        #expect(result7 == false)
        let result8 = detector.update(keyCode: 54, modifierFlags: 0, isModifierEvent: true, timestamp: 1.1)
        #expect(result8 == false)
        let result9 = detector.update(keyCode: 54, modifierFlags: commandFlags, isModifierEvent: true, timestamp: 1.2)
        #expect(result9 == false)
        let result10 = detector.update(keyCode: 54, modifierFlags: 0, isModifierEvent: true, timestamp: 1.3)
        #expect(result10 == true)
    }
}
@Test func leftCommandAndChordsCannotBecomeRightCommandTaps() {
    for (keyCode, flags): (UInt16, UInt) in [(55, 0x100008), (54, 0x100018), (54, 0x120010), (54, 0x140010), (54, 0x180010), (54, 0x900010)] {
        var detector = DoubleTapShortcut()
        for time in [1.0, 1.2] {
            let result11 = detector.update(keyCode: keyCode, modifierFlags: flags, isModifierEvent: true, timestamp: time)
            #expect(result11 == false)
            let result12 = detector.update(keyCode: keyCode, modifierFlags: 0, isModifierEvent: true, timestamp: time + 0.1)
            #expect(result12 == false)
        }
    }
    var detector = DoubleTapShortcut()
    let result13 = detector.update(keyCode: 54, modifierFlags: 0x100010, isModifierEvent: true, timestamp: 1)
    #expect(result13 == false)
    let result14 = detector.update(keyCode: 8, modifierFlags: 0x100010, isModifierEvent: false, timestamp: 1.05)
    #expect(result14 == false)
    let result15 = detector.update(keyCode: 54, modifierFlags: 0, isModifierEvent: true, timestamp: 1.1)
    #expect(result15 == false)
    let result16 = detector.update(keyCode: 54, modifierFlags: 0x100010, isModifierEvent: true, timestamp: 1.2)
    #expect(result16 == false)
    let result17 = detector.update(keyCode: 54, modifierFlags: 0, isModifierEvent: true, timestamp: 1.3)
    #expect(result17 == false)
}
@Test func speechEngineAndNotchPreferencesMigrate() throws {
    let old = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
    #expect(old.speechEngine == .apple)
    var preference = old
    preference.speechEngine = .parakeet; preference.shortcut = 4
    let copy = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preference))
    #expect(copy.speechEngine == .parakeet && copy.shortcut == 4)
    let future = try JSONDecoder().decode(Preferences.self, from: Data("{\"speechEngine\":\"future\"}".utf8))
    #expect(future.speechEngine == .apple)
}

@Test func doubleTapRemembersWhenTheFirstTapWentDown() {
    var tap = DoubleTapShortcut()
    let fired = [tap.update(isDown: true, timestamp: 10.00), tap.update(isDown: false, timestamp: 10.08),
                 tap.update(isDown: true, timestamp: 10.25), tap.update(isDown: false, timestamp: 10.31)]
    #expect(fired == [false, false, false, true])
    #expect(tap.gestureStartedAt == 10.00)
}
