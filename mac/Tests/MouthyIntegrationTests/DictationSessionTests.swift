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
}

@MainActor @Test func dictationSessionStartsIdleAndCancelIsSafe() {
    let session = DictationSession()
    #expect(session.phase == .idle)
    session.cancel()
    #expect(session.phase == .idle && !session.isRunning)
}
