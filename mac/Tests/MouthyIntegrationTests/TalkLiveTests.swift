import Combine
import Foundation
import Testing
import MouthyCore
@testable import MouthyKit

// One real Talk session with the real microphone, speaker and provider. Off unless you run it yourself:
//   MOUTHY_TEST_TALK_LIVE=1 MOUTHY_TALK_API_KEY=<your Gemini key> swift test --filter talkLiveSession
// Optional: MOUTHY_TALK_SECONDS (default 20, the hang-up cap), MOUTHY_TALK_MODEL, MOUTHY_TALK_VOICE.
// Speak once it says "listening"; the model should answer out loud, and talking over it should stop it at once.
// It bills the key's account per token on a paid tier, and the context again every turn (see the Talk ADR for prices).
// The key is read from that environment variable only, used for this one connection and never printed.

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_TALK_LIVE"] == "1"))
func talkLiveSession() async throws {
    let environment = ProcessInfo.processInfo.environment
    let key = try #require(environment["MOUTHY_TALK_API_KEY"], "Set MOUTHY_TALK_API_KEY for the live check.")
    let seconds = Double(environment["MOUTHY_TALK_SECONDS"] ?? "") ?? 20
    let configuration = TalkSessionConfiguration(model: environment["MOUTHY_TALK_MODEL"], voice: environment["MOUTHY_TALK_VOICE"],
                                                 instructions: "Answer in one or two short sentences.",
                                                 maximumDuration: .seconds(seconds))
    let session = TalkSession(configuration: configuration, apiKey: { key })
    var usage: TalkUsage?
    session.onUsage = { usage = $0 }
    var states: [TalkSession.State] = []
    let watcher = session.$state.sink { state in
        if states.last != state { states.append(state); print("talk live: \(state)") }
    }
    defer { watcher.cancel() }
    try await session.start()
    print("talk live: listening for \(Int(seconds)) s; speak now")
    while session.isRunning { try await Task.sleep(for: .milliseconds(100)) }
    // Word counts only: transcripts are never printed or logged.
    for turn in session.transcript { print("talk live: \(turn.role.rawValue) turn, \(turn.text.split(separator: " ").count) words") }
    let used = try #require(usage)
    print("talk live: sent \(used.secondsSent) s, received \(used.secondsReceived) s, tokens \(String(describing: used.tokens))")
    #expect(session.state == .ended(.durationCap))
    #expect(used.secondsSent > seconds / 2)
    #expect(states.contains(.modelSpeaking), "The model never answered out loud.")
}

// Talk's voice-processing audio alone, on this Mac's default microphone and speaker: no network, no provider, no key.
// Off unless you run it yourself:
//   MOUTHY_TEST_TALK_AUDIO=1 swift test --filter talkAudioOpensOnThisMac
// It opens the microphone (macOS asks for permission the first time) and plays a short quiet tone, 2 s at OpenAI's
// rates, then 2 s at Gemini's, stopping in between (each start reconfigures the devices anew, like a host's two tries
// on 2026-10-14). Microphone audio stays in memory and is only counted. `log stream --predicate 'category == "talk"'`
// shows each attempt.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_TALK_AUDIO"] == "1"))
func talkAudioOpensOnThisMac() async throws {
    final class Count: @unchecked Sendable {
        private let lock = NSLock(); private var total = 0
        func add(_ bytes: Int) { lock.withLock { total += bytes } }
        var bytes: Int { lock.withLock { total } }
    }
    for (inputRate, outputRate) in [(24_000.0, 24_000.0), (16_000.0, 24_000.0)] {
        let audio = VoiceProcessingTalkAudio()
        let received = Count()
        var events: [TalkPlayback] = []
        try await audio.start(inputRate: inputRate, outputRate: outputRate, input: { pcm, _ in received.add(pcm.count) },
                              playback: { events.append($0) })
        let tone = (0..<Int(outputRate / 2)).map { Float(0.05 * sin(2 * Double.pi * 440 * Double($0) / outputRate)) }
        audio.play(PCM16.encode(tone), level: 0.05)
        try await Task.sleep(for: .seconds(2))
        let attempt = audio.openedOnAttempt
        audio.stop()
        let seconds = Double(received.bytes) / 2 / inputRate
        print("talk audio: \(Int(inputRate)) Hz in, opened on attempt \(attempt), \(String(format: "%.2f", seconds)) s of microphone audio")
        #expect(seconds > 1, "The microphone delivered too little audio.")
        #expect(events.contains(.drained), "The tone never finished playing.")
        #expect(!events.contains { if case .failed = $0 { true } else { false } })
    }
}

// A whole Talk session through the real voice-processing audio, with the provider played by a scripted in-process
// socket: no network, no provider, no key. Same gate as above, off unless you run it yourself:
//   MOUTHY_TEST_TALK_AUDIO=1 swift test --filter talkSessionRunsOnThisMac
// For OpenAI Realtime, then Gemini Live: the fake accepts the setup, takes 1.5 s of microphone messages, sends 1 s of
// a quiet 440 Hz tone and a finished turn, and the host stops from its state observer once the tone has played.
// Microphone audio stays in memory and is only counted.
@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHY_TEST_TALK_AUDIO"] == "1"))
func talkSessionRunsOnThisMac() async throws {
    func until(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
    /// The microphone audio in what the session sent.
    func microphoneBytes(_ sent: [String]) -> Int {
        sent.reduce(0) { total, message in
            guard let json = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any] else { return total }
            let base64 = json["type"] as? String == "input_audio_buffer.append" ? json["audio"] as? String
                : ((json["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any])?["data"] as? String
            return total + (base64.flatMap { Data(base64Encoded: $0) }?.count ?? 0)
        }
    }
    // 1 s of 440 Hz at 24 kHz and -26 dBFS, in ten 100 ms messages like a provider's stream.
    let tone = (0..<24_000).map { Float(0.05 * sin(2 * Double.pi * 440 * Double($0) / 24_000)) }
    let chunks = stride(from: 0, to: tone.count, by: 2_400).map { PCM16.encode(Array(tone[$0..<$0 + 2_400])).base64EncodedString() }
    let scripts: [(provider: TalkProvider, accept: [String], audio: (String) -> String, done: String)] = [
        (.openAIRealtime, [#"{"type":"session.created","session":{}}"#, #"{"type":"session.updated","session":{}}"#],
         { #"{"type":"response.output_audio.delta","item_id":"item_1","delta":""# + $0 + #""}"# },
         #"{"type":"response.done","response":{"status":"completed","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}"#),
        (.geminiLive, [#"{"setupComplete":{}}"#],
         { #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":""# + $0 + #""}}]}}}"# },
         #"{"usageMetadata":{"promptTokenCount":20,"responseTokenCount":10,"totalTokenCount":30},"serverContent":{"turnComplete":true}}"#),
    ]
    for script in scripts {
        let transport = ScriptedTransport(), audio = VoiceProcessingTalkAudio()
        let session = TalkSession(configuration: TalkSessionConfiguration(provider: script.provider, maximumDuration: .seconds(30)),
                                  apiKey: { "test-key-123" }, transport: transport, audio: audio)
        var reports: [TalkUsage] = []
        session.onUsage = { reports.append($0) }
        var states: [TalkSession.State] = []
        var ends = 0
        // The host stops from its state observer, as a host app does.
        let observer = session.$state.sink { state in
            if states.last != state { states.append(state) }
            if case .ended = state { ends += 1; session.stop() }
        }
        defer { observer.cancel() }

        let starting = Task { try await session.start() }
        #expect(try await until(5) { transport.socket.sent.count == 1 }, "No setup was sent.")
        for message in script.accept { transport.socket.serverSends(message) }
        try await starting.value
        #expect(session.state == .listening)
        let inputRate = script.provider == .openAIRealtime ? 24_000.0 : 16_000.0
        try await Task.sleep(for: .seconds(1.5))
        let heard = Double(microphoneBytes(transport.socket.sent)) / 2 / inputRate

        for chunk in chunks { transport.socket.serverSends(script.audio(chunk)) }
        transport.socket.serverSends(script.done)
        #expect(try await until(5) { session.state == .modelSpeaking }, "The model's audio never started.")
        let speaking = ContinuousClock.now
        var loudest: Float = 0
        let drained = try await until(5) {
            loudest = max(loudest, session.outputLevel.level)
            return session.state == .listening
        }
        let played = (ContinuousClock.now - speaking) / .seconds(1)
        let attempt = audio.openedOnAttempt
        session.stop()

        let usage = try #require(reports.first)
        print("talk session: \(script.provider.rawValue), opened on attempt \(attempt), sent \(String(format: "%.2f", usage.secondsSent)) s (fake heard \(String(format: "%.2f", heard)) s), received \(String(format: "%.2f", usage.secondsReceived)) s, played and drained in \(String(format: "%.2f", played)) s")
        #expect(drained, "The model's audio never finished playing.")
        #expect(states == [.idle, .connecting, .listening, .modelSpeaking, .listening, .ended(.stopped)])
        #expect(heard >= 1, "The fake provider got too little microphone audio.")
        // Played at real time through the speaker, not dropped: draining took about the tone's length.
        #expect(played > 0.8 && loudest > 0)
        #expect(abs(usage.secondsReceived - 1) < 0.01)
        #expect(usage.tokens == TalkTokenCounts(input: 20, output: 10, total: 30))
        #expect(reports.count == 1 && ends == 1 && transport.socket.isClosed)
        try MicrophoneOwner.shared.requireFree()
    }
}
