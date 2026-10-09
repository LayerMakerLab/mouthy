import Foundation
import Testing
import MouthyCore
@testable import MouthyKit

// Settings speaks plain words: no engineering jargon in anything a user reads there,
// and a settings file written by the current release loads with every value unchanged.

private let settingsSources = [
    "Sources/MouthyKit/PreferencesView.swift",
    "Sources/MouthyKit/PreferencesControls.swift",
    "Sources/MouthyKit/PreferenceSection.swift",
    "Sources/MouthyKit/Design/SettingRow.swift",
    "Sources/MouthyKit/Design/SpeechModelsTile.swift",
]

/// Acronyms match case-sensitively as whole words; words match in any case.
private let jargonAcronyms = ["Core ML", "MCP", "HMAC", "AX", "VAD", "LLM", "ONNX"]
private let jargonWords = ["endpoint", "token", "latency", "inference", "sherpa", "onnx", "dylib"]

private func jargon(in text: String) -> [String] {
    var hits: [String] = []
    for word in jargonAcronyms where text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b", options: .regularExpression) != nil {
        hits.append(word)
    }
    for word in jargonWords where text.range(of: word, options: .caseInsensitive) != nil { hits.append(word) }
    return hits
}

private func stringLiterals(_ source: String) -> [String] {
    let regex = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
    return source.split(separator: "\n").flatMap { line -> [String] in
        let line = String(line)
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { return [] }
        return regex.matches(in: line, range: NSRange(line.startIndex..., in: line)).compactMap { Range($0.range, in: line).map { String(line[$0]) } }
    }
}

@Test func settingsStringsHaveNoJargon() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var found: [String] = []
    for path in settingsSources {
        let source = try String(contentsOf: package.appendingPathComponent(path), encoding: .utf8)
        for literal in stringLiterals(source) {
            // The copyable connect command is a command line, not prose; it stays exactly as the tool expects it.
            if literal.hasPrefix("\"claude mcp add") { continue }
            let hits = jargon(in: literal)
            if !hits.isEmpty { found.append("\(path): \(literal) → \(hits.joined(separator: ", "))") }
        }
    }
    #expect(found.isEmpty, "Jargon in Settings: \(found.joined(separator: "\n"))")
}

@Test func speechModelRowsInSettingsHaveNoJargon() {
    for intel in [false, true] {
        for id in SpeechModelID.all.dropFirst() {
            for ready in [false, true] {
                let row = SpeechModelCatalog.row(id, ready: ready, bytes: ready ? 1_000 : 0, supported: true, intel: intel)
                let text = [id.title, row.status, row.size, SpeechModelCatalog.parakeetDetail(intel: intel)].joined(separator: " ")
                #expect(jargon(in: text).isEmpty, "\(text)")
            }
        }
    }
}

@Test func settingsFileFromTheCurrentReleaseLoadsUnchanged() throws {
    // Written by the current release's encoder with non-default values; key names are the stored keys.
    let saved = """
    {"speechEngine":"whisper","whisperModel":"openai_whisper-small_216MB","whisperLanguage":"fr","whisperTranslateToEnglish":true,
     "locale":"fr-FR","inputDeviceUID":"usb-mic","holdToTalk":true,"shortcut":3,"customKeyCode":2,"customModifiers":256,
     "customShortcutLabel":"⌘ D","autoInsert":false,"keepHistory":true,"historyLimit":250,"mode":"Custom",
     "customInstructions":"Short sentences.","vocabulary":"Mouthy\\nParakeet","replacements":[{"phrase":"my sig","replacement":"Thanks"}],
     "punctuationCommands":false,"showOverlay":false,"notchHub":false,"islandCorner":1,"rewriteSelection":true,"smartFormatting":false,
     "mediaWhileDictating":"Pause","playSounds":true,"modes":[],"agentVoice":false,"speakAgentQuestions":true,"localOnly":true,
     "automaticActivation":true,"removeFillers":false,"learnWords":false,"onboarded":true,"syncFolder":"/tmp/sync","checkForUpdates":false}
    """
    let p = try JSONDecoder().decode(Preferences.self, from: Data(saved.utf8))
    #expect(p.speechEngine == .whisper && p.whisperModel == .small && p.whisperLanguage == "fr" && p.whisperTranslateToEnglish)
    #expect(p.locale == "fr-FR" && p.inputDeviceUID == "usb-mic" && p.holdToTalk && p.shortcut == 3)
    #expect(p.customKeyCode == 2 && p.customModifiers == 256 && p.customShortcutLabel == "⌘ D")
    #expect(!p.autoInsert && p.keepHistory && p.historyLimit == 250 && p.mode == .custom && p.customInstructions == "Short sentences.")
    #expect(p.vocabulary == "Mouthy\nParakeet" && p.replacements.map(\.phrase) == ["my sig"] && p.replacements.map(\.replacement) == ["Thanks"])
    #expect(!p.punctuationCommands && !p.showOverlay && !p.notchHub && p.islandCorner == 1 && p.rewriteSelection && !p.smartFormatting)
    #expect(p.mediaWhileDictating == .pause && p.playSounds && !p.agentVoice && p.speakAgentQuestions && p.localOnly)
    #expect(p.automaticActivation && !p.removeFillers && !p.learnWords && p.onboarded && p.syncFolder == "/tmp/sync" && !p.checkForUpdates)

    // Saving again and loading gives the same values: no key renamed or dropped.
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    let once = try encoder.encode(p)
    let twice = try encoder.encode(try JSONDecoder().decode(Preferences.self, from: once))
    #expect(once == twice)
    let keys = Set((try JSONSerialization.jsonObject(with: once) as? [String: Any] ?? [:]).keys)
    let savedKeys = Set((try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any] ?? [:]).keys)
    #expect(savedKeys.isSubset(of: keys), "Missing stored keys: \(savedKeys.subtracting(keys))")
}

/// New installs start on the double tap of the right ⌘. A settings file always stores its shortcut, so every saved
/// choice loads as it was; a file from a build that predates the key keeps ⌃⌥Space, that build's default.
@MainActor @Test func newInstallsStartOnTheDoubleTapAndSavedShortcutsLoadUnchanged() throws {
    #expect(Preferences().shortcut == 4)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthy-shortcut-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fresh = AppModel(store: LocalStore(directory: directory), enablesHotkey: false, speech: FakeSpeech())
    #expect(fresh.preferences.shortcut == 4 && fresh.shortcutLabel == "Double-tap Right ⌘")
    #expect(DictateHero.startPrompt(fresh.shortcutLabel) == "Double-tap Right ⌘ to start")
    // The keycaps show only "Right ⌘", so the words beside them carry the gesture.
    #expect(DictateHero.gesture(preset: 4, holdToTalk: false) == "Double-tap" && DictateHero.gesture(preset: 4, holdToTalk: true) == "Double-tap")
    #expect(DictateHero.gesture(preset: 5, holdToTalk: false) == "Hold" && DictateHero.gesture(preset: 0, holdToTalk: true) == "Hold")
    #expect(DictateHero.gesture(preset: 0, holdToTalk: false) == "Press")

    #expect(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).shortcut == 0)
    for preset in 0...5 {
        let saved = try JSONDecoder().decode(Preferences.self, from: Data("{\"shortcut\":\(preset)}".utf8))
        #expect(saved.shortcut == preset)
        var chosen = Preferences(); chosen.shortcut = preset
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(chosen)) as? [String: Any]
        #expect(written?["shortcut"] as? Int == preset, "the shortcut is always written, so the default never replaces a choice")
    }

    // Onboarding names the gesture in plain words, never as a run of glued keys.
    #expect(OnboardingView.shortcutAction(preset: 4, label: "Double-tap Right ⌘") == "double-tap Right ⌘")
    #expect(OnboardingView.shortcutAction(preset: 5, label: "Hold Fn") == "hold Fn")
    #expect(OnboardingView.shortcutAction(preset: 0, label: "⌃ ⌥ Space") == "press ⌃⌥Space")
    #expect(OnboardingView.shortcutAction(preset: 3, label: "⌘ D") == "press ⌘D")
}
