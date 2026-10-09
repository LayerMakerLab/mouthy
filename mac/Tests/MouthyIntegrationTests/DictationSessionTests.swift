import Testing
import MouthyCore
@testable import MouthyKit

@Test func dictationShapesProseAndCodeForHosts() {
    let prose = DictationConfiguration(replacements: [Replacement(phrase: "sample app", replacement: "SampleApp")])
    #expect(DictationSession.shape("ask sample app to fix it period", with: prose) == "ask SampleApp to fix it.")
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
