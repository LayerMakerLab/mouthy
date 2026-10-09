import Testing
import Foundation
@testable import MouthyCore

@Test func backupValidationKeepsModesAndRejectsBrokenFiles() throws {
    var prefs = Preferences(); prefs.shortcut = 5
    var mode = DictationMode(name: "Code"); mode.codeDictation = true
    prefs.modes = [mode]
    let restored = try SettingsBackup.read(JSONEncoder().encode(SettingsBackup(prefs)))
    #expect(restored.shortcut == 5 && restored.modes.first?.codeDictation == true)
    #expect(throws: (any Error).self) { try SettingsBackup.read(Data("broken".utf8)) }
}
