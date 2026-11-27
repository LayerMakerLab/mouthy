import Testing
import MouthyCore
@testable import MouthyKit

@MainActor @Test func dictationShapesProseAndCodeForHosts() {
    let prose = DictationConfiguration(replacements: [Replacement(phrase: "sample app", replacement: "SampleApp")])
    #expect(DictationSession.shape("ask sample app to fix it period", with: prose) == "Ask SampleApp to fix it.")
    // Host apps get Mouthy's whole cleanup: fillers and clock times too.
    #expect(DictationSession.shape("um meet at 3.30 period", with: prose) == "Meet at 3:30.")
    // A snippet on its own comes back exactly as written.
    let snippet = DictationConfiguration(replacements: [Replacement(phrase: "my email", replacement: "dana@example.com")])
    #expect(DictationSession.shape("My email.", with: snippet) == "dana@example.com")
    // A run-together or one-letter-off custom term is written as the term; real words are left alone.
    let terms = DictationConfiguration(vocabulary: "X Grower")
    #expect(DictationSession.shape("Then check what Xcrower found and explore XGrower.", with: terms)
            == "Then check what X Grower found and explore X Grower.")
    var code = DictationConfiguration(textStyle: .code)
    code.replacements = []
    #expect(DictationSession.shape("git commit dash m", with: code) == "git commit -m")
    // Ordinary dictation: a spoken dash joins the words around it and "dot com" ends an address; a code style keeps
    // its own symbols (above), and with spoken commands off the words stay words.
    let plain = DictationConfiguration()
    #expect(DictationSession.shape("name it maple dash design period", with: plain) == "Name it maple-design.")
    #expect(DictationSession.shape("example dot com is down at 3.30 period", with: plain) == "example.com is down at 3:30.")
    #expect(DictationText.shape("name it maple dash design", code: false, replacements: [], punctuation: false, removeFillers: true,
                                vocabulary: "") == "Name it maple dash design")
    #expect(DictationSession.shape("open readme dot md and run git commit dash m period", with: plain) == "Open readme.md and run git commit -m.")
    #expect(DictationSession.shape("type slash help and name it user underscore name", with: plain) == "Type /help and name it user_name")
    // A mark that is one of the person's own words stays a word, and a live guess holds back a mark that ends it.
    #expect(DictationText.shape("I use Dash for docs", code: false, replacements: [], punctuation: true, removeFillers: true,
                                vocabulary: "Mouthy\nDash") == "I use Dash for docs")
    var settings = Preferences()
    settings.vocabulary = "Dash"
    #expect(DictationText.shape("I use Dash for docs", code: false, config: settings) == "I use Dash for docs")
    #expect(DictationText.shape("name it maple dash", code: false, config: Preferences(), live: true) == "Name it maple")
    #expect(DictationText.shape("name it maple dash", code: false, config: Preferences()) == "Name it maple dash")
    // A dictation that begins with "slash" and a word is a command, as the recognizer writes it and through every
    // text rule: no capital, no closing period. While the person is still speaking nothing of it shows.
    #expect(DictationText.shape("Slash clear.", code: false, config: Preferences()) == "/clear")
    #expect(DictationText.shape("Slash code dash review.", code: false, config: Preferences()) == "/code-review")
    #expect(DictationText.shape("Slash clear.", code: false, config: Preferences(), live: true) == "")
    #expect(DictationText.shape("Slash the budget in half.", code: false, config: Preferences()) == "Slash the budget in half.")
    // In a field after other text it is fitted like any word, and stays a command.
    #expect(SmartInsertion.adjust("/clear", before: "", after: "") == "/clear")
    #expect(SmartInsertion.adjust("/clear", before: "Then run", after: "") == " /clear")
}

@MainActor @Test func dictationSessionStartsIdleAndCancelIsSafe() {
    let session = DictationSession()
    #expect(session.phase == .idle)
    session.cancel()
    #expect(session.phase == .idle && !session.isRunning)
}
