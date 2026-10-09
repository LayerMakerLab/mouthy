import Foundation

public struct Replacement: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var phrase: String
    public var replacement: String
    public init(id: UUID = UUID(), phrase: String, replacement: String) {
        self.id = id; self.phrase = phrase; self.replacement = replacement
    }
    enum CodingKeys: String, CodingKey { case id, phrase, replacement }
    /// Tolerates a missing id (sync files written by the Windows/Linux app).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        phrase = try c.decode(String.self, forKey: .phrase)
        replacement = try c.decode(String.self, forKey: .replacement)
    }
}

public enum WritingMode: String, CaseIterable, Codable, Identifiable {
    case verbatim = "Natural", grammar = "Grammar", tidy = "Clean up", concise = "Concise", custom = "Custom"
    public var id: String { rawValue }
    public var instructions: String {
        switch self {
        case .verbatim: return ""
        case .grammar: return "Correct punctuation, capitalization, spelling and grammar, and format numbers, dates and lists naturally. Keep the speaker's words, word order and meaning. Do not rephrase, shorten, summarize or add anything."
        case .tidy: return "Fix punctuation and remove verbal fillers. Preserve meaning, names, numbers, and the speaker's voice."
        case .concise: return "Make the text concise while preserving every factual claim, name and number."
        case .custom: return ""
        }
    }
}

public struct Transcript: Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var raw: String
    public var text: String
    public var duration: Double
    public var source: String
    public var mode: String
    public init(raw: String, text: String, duration: Double, source: String, mode: String) {
        id = UUID(); date = Date(); self.raw = raw; self.text = text
        self.duration = duration; self.source = source; self.mode = mode
    }
}

public enum SpeechEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, parakeet, whisper
    public var id: String { rawValue }
    public var label: String {
        switch self { case .apple: return "Apple Speech"; case .parakeet: return "NVIDIA Parakeet v3"; case .whisper: return "OpenAI Whisper" }
    }
}
public enum WhisperModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case baseEnglish = "openai_whisper-base.en"
    case small = "openai_whisper-small_216MB"
    case medium = "openai_whisper-medium"
    case turbo = "openai_whisper-large-v3-v20240930_626MB"
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .baseEnglish: return "Base English · smallest"
        case .small: return "Small · multilingual"
        case .medium: return "Medium · translation, more memory"
        case .turbo: return "Large v3 Turbo · multilingual"
        }
    }
    public var supportsTranslation: Bool { self == .small || self == .medium }
}
public enum MediaWhileDictating: String, Codable, CaseIterable, Identifiable {
    case nothing = "Leave playing", mute = "Mute", pause = "Pause"
    public var id: String { rawValue }
}

public struct Preferences: Codable {
    public var speechEngine: SpeechEngine = .apple
    public var whisperModel: WhisperModel = .baseEnglish
    public var whisperLanguage = "auto"
    public var whisperTranslateToEnglish = false
    public var locale = "en-US"
    public var inputDeviceUID = ""
    public var holdToTalk = false
    /// The dictation shortcut: 0-2 the ⌃⌥Space, ⌘⇧Space and ⌃⇧Space presets, 3 custom, 4 double-tap Right ⌘, 5 hold Fn.
    /// New installs start on the double tap. A settings file without this key comes from an older build whose
    /// default was ⌃⌥Space, so decoding keeps that rather than switching an existing person's shortcut.
    public var shortcut = 4
    public var customKeyCode: UInt32 = 49
    public var customModifiers: UInt32 = 6144
    public var customShortcutLabel = "⌃ ⌥ Space"
    public var autoInsert = true
    public var keepHistory = false
    public var historyLimit = 100
    public var mode: WritingMode = .verbatim
    public var customInstructions = "Preserve my wording and organize it into clear paragraphs."
    public var vocabulary = ""
    public var replacements: [Replacement] = []
    public var punctuationCommands = true
    public var showOverlay = true
    /// The notch hub: tabs for timers, notes, music, clipboard, shelf, calendar and AI usage.
    public var notchHub = true
    /// Recording display on displays without a notch: 0 top centre, 1 bottom left, 2 bottom right.
    public var islandCorner = 2
    public var rewriteSelection = false
    public var smartFormatting = true
    public var mediaWhileDictating: MediaWhileDictating = .nothing
    public var playSounds = false
    public var modes: [DictationMode] = []
    public var agentVoice = true
    public var speakAgentQuestions = false
    /// Local Only Mode: no network use at all, including model downloads.
    public var localOnly = false
    /// "Automatic" style: a tap toggles recording, a long press records until release.
    public var automaticActivation = false
    /// Drop "um", "uh", "erm" (instant, no AI).
    public var removeFillers = true
    /// Add words the person corrects after insertion to the vocabulary.
    public var learnWords = true
    /// First-run setup finished. Fresh installs start false; existing settings files count as set up.
    public var onboarded = false
    /// Folder holding "Mouthy Sync.json" (any synced or shared folder); empty turns sync off.
    public var syncFolder = ""
    /// A daily check of mouthy.dev for a new version, downloaded quietly and installed when Mouthy quits.
    /// On by default; Local Only Mode also stops it.
    public var checkForUpdates = true
    /// "Only listen to my voice": other voices (a TV, people nearby) are turned down like other non-voice sound.
    /// Off until the person trains their voiceprint; Parakeet and Whisper only.
    public var onlyMyVoice = false
    public init() {}
    enum CodingKeys: String, CodingKey {
        case speechEngine, whisperModel, whisperLanguage, whisperTranslateToEnglish, locale, inputDeviceUID, holdToTalk, shortcut, customKeyCode, customModifiers, customShortcutLabel, autoInsert, keepHistory, historyLimit, mode,
             customInstructions, vocabulary, replacements, punctuationCommands, showOverlay, notchHub, islandCorner, rewriteSelection, 
             smartFormatting, mediaWhileDictating, playSounds, modes, agentVoice, speakAgentQuestions, localOnly, automaticActivation, removeFillers, learnWords, onboarded, syncFolder, checkForUpdates, onlyMyVoice
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        speechEngine = (try? c.decode(SpeechEngine.self, forKey: .speechEngine)) ?? .apple
        whisperModel = (try? c.decode(WhisperModel.self, forKey: .whisperModel)) ?? .baseEnglish
        whisperLanguage = try c.decodeIfPresent(String.self, forKey: .whisperLanguage) ?? "auto"
        whisperTranslateToEnglish = try c.decodeIfPresent(Bool.self, forKey: .whisperTranslateToEnglish) ?? false
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? "en-US"
        inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID) ?? ""
        holdToTalk = try c.decodeIfPresent(Bool.self, forKey: .holdToTalk) ?? false
        shortcut = try c.decodeIfPresent(Int.self, forKey: .shortcut) ?? 0
        customKeyCode = try c.decodeIfPresent(UInt32.self, forKey: .customKeyCode) ?? 49
        customModifiers = try c.decodeIfPresent(UInt32.self, forKey: .customModifiers) ?? 6144
        customShortcutLabel = try c.decodeIfPresent(String.self, forKey: .customShortcutLabel) ?? "⌃ ⌥ Space"
        autoInsert = try c.decodeIfPresent(Bool.self, forKey: .autoInsert) ?? true
        keepHistory = try c.decodeIfPresent(Bool.self, forKey: .keepHistory) ?? false
        historyLimit = max(10, min(1000, try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 100))
        mode = try c.decodeIfPresent(WritingMode.self, forKey: .mode) ?? .verbatim
        customInstructions = try c.decodeIfPresent(String.self, forKey: .customInstructions) ?? "Preserve my wording and organize it into clear paragraphs."
        vocabulary = try c.decodeIfPresent(String.self, forKey: .vocabulary) ?? ""
        replacements = try c.decodeIfPresent([Replacement].self, forKey: .replacements) ?? []
        punctuationCommands = try c.decodeIfPresent(Bool.self, forKey: .punctuationCommands) ?? true
        showOverlay = try c.decodeIfPresent(Bool.self, forKey: .showOverlay) ?? true
        notchHub = try c.decodeIfPresent(Bool.self, forKey: .notchHub) ?? true
        islandCorner = try c.decodeIfPresent(Int.self, forKey: .islandCorner) ?? 2
        rewriteSelection = try c.decodeIfPresent(Bool.self, forKey: .rewriteSelection) ?? false
        smartFormatting = try c.decodeIfPresent(Bool.self, forKey: .smartFormatting) ?? true
        mediaWhileDictating = (try? c.decode(MediaWhileDictating.self, forKey: .mediaWhileDictating)) ?? .nothing
        playSounds = try c.decodeIfPresent(Bool.self, forKey: .playSounds) ?? false
        modes = (try? c.decodeIfPresent([DictationMode].self, forKey: .modes)) ?? []
        agentVoice = try c.decodeIfPresent(Bool.self, forKey: .agentVoice) ?? true
        speakAgentQuestions = try c.decodeIfPresent(Bool.self, forKey: .speakAgentQuestions) ?? false
        localOnly = try c.decodeIfPresent(Bool.self, forKey: .localOnly) ?? false
        automaticActivation = try c.decodeIfPresent(Bool.self, forKey: .automaticActivation) ?? false
        removeFillers = try c.decodeIfPresent(Bool.self, forKey: .removeFillers) ?? true
        learnWords = try c.decodeIfPresent(Bool.self, forKey: .learnWords) ?? true
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? true
        syncFolder = try c.decodeIfPresent(String.self, forKey: .syncFolder) ?? ""
        checkForUpdates = try c.decodeIfPresent(Bool.self, forKey: .checkForUpdates) ?? true
        onlyMyVoice = try c.decodeIfPresent(Bool.self, forKey: .onlyMyVoice) ?? false
    }
}

public enum TextPipeline {
    public static func process(_ text: String, replacements: [Replacement], punctuation: Bool) -> String {
        var output = stripLeadingPunctuation(removeHesitationDots(text))
        if punctuation { output = Backtrack.apply(output) }
        // Longest match wins. A single pass prevents replacement text becoming another rule's input.
        var rules = replacements.filter { !$0.phrase.trimmingCharacters(in: .whitespaces).isEmpty }
        rules.sort { $0.phrase.count > $1.phrase.count }
        guard !rules.isEmpty else { return punctuation ? SpokenPunctuation.apply(output) : output }
        let alternatives = rules.map { NSRegularExpression.escapedPattern(for: $0.phrase) }
        let pattern = "(?<![\\p{L}\\p{N}_])(?:" + alternatives.joined(separator: "|") + ")(?![\\p{L}\\p{N}_])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return output }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output) else { continue }
            let phrase = String(output[range])
            if let rule = rules.first(where: { $0.phrase.caseInsensitiveCompare(phrase) == .orderedSame }) {
                output.replaceSubrange(range, with: rule.replacement)
            }
        }
        if punctuation { output = SpokenPunctuation.apply(output) }
        output = output.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Apple's recognizer writes hesitations as "..." or "…"; drop them and tidy the commas left behind.
public func removeHesitationDots(_ text: String) -> String {
    var out = text.replacingOccurrences(of: "\\s*(?:\\.{2,}|…)+", with: "", options: .regularExpression)
    out = out.replacingOccurrences(of: "\\s*,(?:\\s*,)+", with: ",", options: .regularExpression)
    out = out.replacingOccurrences(of: "\\s+([,.;:!?])", with: "$1", options: .regularExpression)
    return out
}

/// Removes pause artifacts ("...", "…", stray commas) before the first word.
public func stripLeadingPunctuation(_ text: String) -> String {
    let stray = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:…!?-–—"))
    return String(text.unicodeScalars.drop { stray.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines)
}

public struct TranscriptAccumulator {
    public private(set) var finalSegments: [String] = []
    public private(set) var partial = ""
    /// Final segments already sent by a mid-dictation split.
    public private(set) var consumed = 0
    public init() {}
    public mutating func accept(_ text: String, isFinal: Bool) {
        // Pauses can come back as bare punctuation ("..."); keep only segments with words.
        let words = text.contains { $0.isLetter || $0.isNumber }
        if isFinal { if words { finalSegments.append(text.trimmingCharacters(in: .whitespacesAndNewlines)) }; partial = "" }
        else { partial = words ? text : "" }
    }
    private var pending: ArraySlice<String> { finalSegments[min(consumed, finalSegments.count)...] }
    public var finalText: String { pending.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    public var preview: String { (Array(pending) + [partial]).filter { !$0.isEmpty }.joined(separator: " ") }
    /// Returns the finalized text not yet sent and marks it sent.
    public mutating func takeFinalized() -> String {
        let text = finalText
        consumed = finalSegments.count
        return text
    }
}

/// Paste into whatever is focused when dictation finishes.
/// Refuse only targets that certainly cannot take text, and never type into password fields.
/// Unknown roles (web editors report AXGroup/AXWebArea; GPU terminals and games report AXWindow) are allowed.
public enum DeliveryPolicy {
    public static let nonEditableRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenuItem", "AXMenu",
        "AXMenuBar", "AXMenuBarItem", "AXStaticText", "AXImage", "AXLink", "AXDisclosureTriangle",
        "AXScrollBar", "AXSlider", "AXIncrementor", "AXTabGroup", "AXToolbar", "AXSplitter", "AXDockItem"]
    public static func refusal(role: String?, subrole: String?, secureInput: Bool) -> String? {
        if secureInput || subrole == "AXSecureTextField" { return "A password field is active; nothing was inserted." }
        if let role, nonEditableRoles.contains(role) { return "The focused item does not accept text." }
        return nil
    }
}

/// Picks a speech locale for a keyboard language ("es", "pt-BR"), preferring the person's region.
public enum LocaleMatcher {
    public static func best(language: String, region: String?, available: [String], fallback: String) -> String {
        let parts = language.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let code = parts.first?.lowercased() else { return fallback }
        let wantedRegion = parts.count > 1 ? parts.last!.uppercased() : region?.uppercased()
        let matches = available.filter { $0.lowercased().hasPrefix(code + "-") || $0.lowercased() == code }
        if let wantedRegion, let exact = matches.first(where: { $0.uppercased().hasSuffix("-" + wantedRegion) }) { return exact }
        let defaults = ["en": "en-US", "es": "es-ES", "fr": "fr-FR", "de": "de-DE", "pt": "pt-BR", "it": "it-IT", "zh": "zh-CN", "ja": "ja-JP"]
        if let preferred = defaults[code], matches.contains(preferred) { return preferred }
        return matches.first ?? fallback
    }
}
