import Combine
import AVFoundation
import Foundation
import Testing
import MouthyCore
@testable import MouthyKit

// Talk sessions against a scripted socket and a fake microphone and speaker: no network, key store, microphone or
// speaker is touched. The microphone owner is process-wide, so these run one at a time.

private struct ScriptedError: Error, LocalizedError {
    var errorDescription: String? { "No key saved for Gemini." }
}

/// A socket the test plays the server for.
final class ScriptedSocket: TalkSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sentMessages: [String] = []
    private var closed = false
    private let inbox: AsyncThrowingStream<String, Error>
    private let server: AsyncThrowingStream<String, Error>.Continuation
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator?

    init() {
        (inbox, server) = AsyncThrowingStream<String, Error>.makeStream()
        iterator = inbox.makeAsyncIterator()
    }

    var sent: [String] { lock.withLock { sentMessages } }
    var isClosed: Bool { lock.withLock { closed } }
    func serverSends(_ message: String) { server.yield(message) }
    func serverCloses(code: Int = 1008, reason: String) { server.finish(throwing: TalkSocketClosed(code: code, reason: reason)) }

    func send(_ message: String) async throws { lock.withLock { sentMessages.append(message) } }
    func receive() async throws -> String {
        var next = lock.withLock { iterator }
        guard let message = try await next?.next() else { throw TalkSocketClosed(code: 1000, reason: "") }
        lock.withLock { iterator = next }
        return message
    }
    func close() { lock.withLock { closed = true }; server.finish() }
}

final class ScriptedTransport: TalkTransport, @unchecked Sendable {
    let socket = ScriptedSocket()
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    var refuse: String?
    var connected: [URLRequest] { lock.withLock { requests } }
    func connect(_ request: URLRequest) async throws -> any TalkSocket {
        lock.withLock { requests.append(request) }
        if let refuse { throw TalkSocketClosed(code: 401, reason: refuse) }
        return socket
    }
}

@MainActor final class FakeTalkAudio: TalkAudio {
    var startError: Error?
    /// Runs while start is still opening the microphone (a permission prompt, say).
    var whileStarting: (@MainActor () -> Void)?
    /// What the next flush reports as unheard.
    var unplayed = 0.0
    private(set) var rates: (input: Double, output: Double)?
    private(set) var started = 0, stopped = 0, flushed = 0
    private(set) var played: [Data] = []
    private var input: (@Sendable (Data, Float) -> Void)?
    private var playback: (@MainActor (TalkPlayback) -> Void)?

    func start(inputRate: Double, outputRate: Double, input: @escaping @Sendable (Data, Float) -> Void,
               playback: @escaping @MainActor (TalkPlayback) -> Void) async throws {
        rates = (inputRate, outputRate)
        whileStarting?()
        if let startError { throw startError }
        started += 1
        self.input = input; self.playback = playback
    }
    func play(_ pcm16: Data, level: Float) { played.append(pcm16); playback?(.level(level)) }
    func flush() -> Double { flushed += 1; playback?(.level(0)); return unplayed }
    func stop() { stopped += 1; input = nil; playback = nil }
    /// The person speaks: `seconds` of audio at the rate the session asked for.
    func speak(seconds: Double) { input?(PCM16.encode([Float](repeating: 0.2, count: Int((rates?.input ?? 0) * seconds))), 0.6) }
    func finishPlaying() { playback?(.level(0)); playback?(.drained) }
    func unplug() { playback?(.failed("The microphone or speaker changed, so Talk ended.")) }
}

/// One fake try at opening voice-processing I/O, for `VoiceProcessingTalkAudio`'s retries.
@MainActor final class FakeTalkEngine: TalkAudioEngine {
    static let microphone = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    var failure: Error?
    /// Whether a configuration change can be resumed in place.
    var resumes = true
    private(set) var started = 0, stopped = 0
    private var tap: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var changed: (@MainActor @Sendable () -> Void)?

    func start(outputRate: Double, tap: (AVAudioFormat) -> @Sendable (AVAudioPCMBuffer) -> Void,
               configurationChanged: @escaping @MainActor @Sendable () -> Void) throws -> AVAudioFormat {
        if let failure { throw failure }
        started += 1
        self.tap = tap(Self.microphone); changed = configurationChanged
        return Self.microphone
    }
    func resume() -> Bool { resumes }
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void) {}
    func flushPlayer() {}
    func stop() { stopped += 1 }
    func configurationChange() { changed?() }
    /// The person speaks into this engine's microphone.
    func speak(seconds: Double) {
        let frames = AVAudioFrameCount(Self.microphone.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.microphone, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = 0.2 }
        tap?(buffer)
    }
}

/// Makes the fake engines (the first `failing` of them fail like a host's 2026-10-14 start) and records the settles.
@MainActor final class EngineBench {
    static let raceError = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10875)
    var failing: Int
    private(set) var engines: [FakeTalkEngine] = []
    private(set) var settles: [Int] = []
    /// Holds each settle until the test resumes it.
    var holdSettles = false
    private(set) var held: CheckedContinuation<Void, Never>?

    init(failing: Int) { self.failing = failing }

    func audio() -> VoiceProcessingTalkAudio {
        VoiceProcessingTalkAudio(makeEngine: { [unowned self] in
            let engine = FakeTalkEngine()
            if self.engines.count < self.failing { engine.failure = Self.raceError }
            self.engines.append(engine)
            return engine
        }, settle: { [unowned self] retry in
            self.settles.append(retry)
            if self.holdSettles { await withCheckedContinuation { self.held = $0 } }
        }, permission: { true })
    }

    func release() { held?.resume(); held = nil }
}

/// A microphone permission prompt the test answers, holding `SpeechService.start` at its first await.
@MainActor final class HeldPermission {
    private var waiting: CheckedContinuation<Bool?, Never>?
    var isAsking: Bool { waiting != nil }
    func ask() async -> Bool? { await withCheckedContinuation { waiting = $0 } }
    func answer(_ granted: Bool) { waiting?.resume(returning: granted); waiting = nil }
}

@MainActor private func until(_ condition: @MainActor () -> Bool, seconds: Double = 2) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition() {
        guard ContinuousClock.now < deadline else { Issue.record("Condition not met in time"); return }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private let setupComplete = #"{"setupComplete":{}}"#
private func modelAudio(seconds: Double) -> String {
    let pcm = PCM16.encode([Float](repeating: 0.3, count: Int(24_000 * seconds)))
    return #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":""# + pcm.base64EncodedString() + #""}}]}}}"#
}

@MainActor private func makeSession(_ transport: ScriptedTransport, _ audio: any TalkAudio, cap: Duration = .seconds(60),
                                    key: @escaping @Sendable () async throws -> String = { "test-key-123" }) -> TalkSession {
    TalkSession(configuration: TalkSessionConfiguration(voice: "Kore", maximumDuration: cap), apiKey: key, transport: transport, audio: audio)
}

/// Starts a session and plays the server's setupComplete.
@MainActor private func startListening(_ session: TalkSession, _ transport: ScriptedTransport) async throws {
    let starting = Task { try await session.start() }
    try await until { transport.socket.sent.count == 1 }
    #expect(session.state == .connecting)
    transport.socket.serverSends(setupComplete)
    try await starting.value
}

@Suite(.serialized) @MainActor struct TalkSessionTests {
    /// Mute keeps the call up and the microphone open, but nothing spoken reaches the provider or the meter.
    @Test func mutedMicrophoneSendsNothing() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio)
        try await startListening(session, transport)
        session.isMuted = true
        audio.speak(seconds: 0.5)
        try await Task.sleep(for: .milliseconds(50))
        #expect(transport.socket.sent.count == 1, "only the setup went out")
        #expect(session.inputLevel.level == 0 && session.usage.secondsSent == 0)
        #expect(session.state == .listening && audio.stopped == 0, "the call and the microphone stay open")
        session.isMuted = false
        audio.speak(seconds: 0.5)
        try await until { transport.socket.sent.count == 2 }
        #expect(abs(session.usage.secondsSent - 0.5) < 0.001 && session.inputLevel.level > 0)
        session.stop()
    }

    @Test func conversationRunsThroughEveryState() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio)
        var reports: [TalkUsage] = []
        session.onUsage = { reports.append($0) }
        #expect(session.state == .idle)
        try await startListening(session, transport)
        #expect(session.state == .listening && audio.started == 1)
        // The key went in the header only, and the setup went first.
        let request = try #require(transport.connected.first)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key-123")
        #expect(!(request.url?.absoluteString.contains("test-key-123") ?? true))
        #expect(transport.socket.sent.first?.hasPrefix(#"{"setup":"#) == true)
        // Dictation says why it can't run while Talk has the microphone.
        #expect(throws: (any Error).self) { try MicrophoneOwner.shared.requireFree() }

        audio.speak(seconds: 0.5)
        try await until { transport.socket.sent.count == 2 }
        #expect(transport.socket.sent[1].contains(#""mimeType":"audio/pcm;rate=16000""#))
        #expect(session.inputLevel.level > 0)

        transport.socket.serverSends(#"{"serverContent":{"inputTranscription":{"text":"Hello there"}}}"#)
        transport.socket.serverSends(modelAudio(seconds: 0.25))
        transport.socket.serverSends(#"{"serverContent":{"outputTranscription":{"text":"Hi there."}}}"#)
        try await until { session.state == .modelSpeaking }
        #expect(audio.played.count == 1 && session.outputLevel.level > 0)
        transport.socket.serverSends(#"{"usageMetadata":{"promptTokenCount":40,"responseTokenCount":20,"totalTokenCount":60},"serverContent":{"turnComplete":true}}"#)
        try await until { session.transcript.allSatisfy(\.isComplete) && session.transcript.count == 2 }
        // The turn is over but its speech is still playing.
        #expect(session.state == .modelSpeaking)
        audio.finishPlaying()
        #expect(session.state == .listening && session.outputLevel.level == 0)
        #expect(session.transcript.map(\.text) == ["Hello there", "Hi there."])
        #expect(session.transcript.map(\.role) == [.user, .model])

        session.stop()
        #expect(session.state == .ended(.stopped))
        #expect(audio.stopped == 1 && transport.socket.isClosed)
        #expect(reports.count == 1)
        let usage = try #require(reports.first)
        #expect(abs(usage.secondsSent - 0.5) < 0.001 && abs(usage.secondsReceived - 0.25) < 0.001)
        #expect(usage.tokens == TalkTokenCounts(input: 40, output: 20, total: 60))
        #expect(usage.model == "gemini-3.8-live" && usage.provider == .geminiLive)
        // Everything is back: dictation may record again, and a second stop reports nothing more.
        try MicrophoneOwner.shared.requireFree()
        session.stop()
        #expect(reports.count == 1 && audio.stopped == 1)
    }

    @Test func bargeInStopsPlaybackAtOnce() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio)
        try await startListening(session, transport)
        transport.socket.serverSends(modelAudio(seconds: 1))
        transport.socket.serverSends(#"{"serverContent":{"outputTranscription":{"text":"Once upon a"}}}"#)
        try await until { session.state == .modelSpeaking && session.transcript.count == 1 }
        transport.socket.serverSends(#"{"serverContent":{"interrupted":true}}"#)
        try await until { session.state == .listening }
        #expect(audio.flushed == 1 && session.outputLevel.level == 0)
        #expect(session.transcript.first?.isComplete == true)
        // The next answer is a new model turn.
        transport.socket.serverSends(#"{"serverContent":{"outputTranscription":{"text":"Sure."}}}"#)
        try await until { session.transcript.count == 2 }
        session.stop()
    }

    @Test func hangsUpByItselfAtTheDurationCap() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio, cap: .milliseconds(300))
        var reports = 0
        session.onUsage = { _ in reports += 1 }
        try await startListening(session, transport)
        try await until({ session.state != .listening }, seconds: 3)
        #expect(session.state == .ended(.durationCap))
        #expect(audio.stopped == 1 && transport.socket.isClosed && reports == 1)
        try MicrophoneOwner.shared.requireFree()
    }

    @Test func aKeyThatFailsToLoadEndsBeforeConnecting() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio, key: { throw ScriptedError() })
        var reports = 0
        session.onUsage = { _ in reports += 1 }
        await #expect(throws: TalkFailure(reason: .keyUnavailable("No key saved for Gemini."))) { try await session.start() }
        #expect(session.state == .ended(.keyUnavailable("No key saved for Gemini.")))
        #expect(transport.connected.isEmpty && audio.started == 0 && reports == 0)
        try MicrophoneOwner.shared.requireFree()

        let empty = makeSession(ScriptedTransport(), audio, key: { "  " })
        await #expect(throws: TalkFailure(reason: .keyUnavailable("The key is empty."))) { try await empty.start() }
    }

    @Test func aServerThatClosesBeforeSetupFailsTheStart() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio)
        var reports = 0
        session.onUsage = { _ in reports += 1 }
        let starting = Task { try await session.start() }
        try await until { transport.socket.sent.count == 1 }
        transport.socket.serverCloses(reason: "API key not valid. Please pass a valid API key.")
        await #expect(throws: TalkFailure(reason: .connectionFailed("API key not valid. Please pass a valid API key."))) { try await starting.value }
        #expect(audio.started == 0 && transport.socket.isClosed)
        // It reached the provider, so the (empty) usage is still reported for the ledger.
        #expect(reports == 1 && session.usage.secondsSent == 0)
        try MicrophoneOwner.shared.requireFree()

        let refused = ScriptedTransport()
        refused.refuse = "The provider refused the connection (HTTP 403)."
        let other = makeSession(refused, audio)
        await #expect(throws: TalkFailure(reason: .connectionFailed("The provider refused the connection (HTTP 403)."))) { try await other.start() }
    }

    @Test func aServerThatClosesMidSessionEndsIt() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio)
        try await startListening(session, transport)
        transport.socket.serverSends(modelAudio(seconds: 0.5))
        try await until { session.state == .modelSpeaking }
        transport.socket.serverCloses(code: 1011, reason: "Internal error.")
        try await until { !session.isRunning }
        #expect(session.state == .ended(.serverClosed("Internal error.")))
        #expect(audio.stopped == 1)
        try MicrophoneOwner.shared.requireFree()
    }

    @Test func stopWhileConnectingAndAudioFailures() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio)
        let starting = Task { try await session.start() }
        try await until { transport.socket.sent.count == 1 }
        session.stop()
        await #expect(throws: TalkFailure(reason: .stopped)) { try await starting.value }
        #expect(audio.started == 0)

        let denied = FakeTalkAudio()
        denied.startError = TalkFailure(reason: .microphoneDenied)
        let deniedTransport = ScriptedTransport()
        let second = makeSession(deniedTransport, denied)
        let secondStart = Task { try await second.start() }
        try await until { deniedTransport.socket.sent.count == 1 }
        deniedTransport.socket.serverSends(setupComplete)
        await #expect(throws: TalkFailure(reason: .microphoneDenied)) { try await secondStart.value }
        #expect(deniedTransport.socket.isClosed)

        // A stop while the microphone opens leaves nothing running.
        let late = FakeTalkAudio()
        let lateTransport = ScriptedTransport()
        let fourth = makeSession(lateTransport, late)
        late.whileStarting = { fourth.stop() }
        let lateStart = Task { try await fourth.start() }
        try await until { lateTransport.socket.sent.count == 1 }
        lateTransport.socket.serverSends(setupComplete)
        await #expect(throws: TalkFailure(reason: .stopped)) { try await lateStart.value }
        #expect(late.started == 1 && late.stopped == 2)

        let unplugTransport = ScriptedTransport()
        let third = makeSession(unplugTransport, audio)
        try await startListening(third, unplugTransport)
        audio.unplug()
        #expect(third.state == .ended(.audioFailed("The microphone or speaker changed, so Talk ended.")))
        try MicrophoneOwner.shared.requireFree()
    }

    @Test func talkWaitsForADictationAndOnlyOneTalkRuns() async throws {
        final class Recorder {}
        let recorder = Recorder()
        var recording = true
        MicrophoneOwner.shared.register(recorder) { [weak recorder] in recorder != nil && recording }
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio)
        await #expect(throws: TalkFailure(reason: .microphoneBusy)) { try await session.start() }
        #expect(transport.connected.isEmpty)
        recording = false

        let first = makeSession(transport, audio)
        try await startListening(first, transport)
        let second = makeSession(ScriptedTransport(), FakeTalkAudio())
        await #expect(throws: TalkFailure(reason: .microphoneBusy)) { try await second.start() }
        #expect(first.state == .listening)
        first.stop()
        _ = recorder
    }

    @Test func dictationAndMeetingsSayTalkHasTheMicrophone() async throws {
        let talk = makeSession(ScriptedTransport(), FakeTalkAudio())
        try MicrophoneOwner.shared.claimForTalk(talk)
        defer { MicrophoneOwner.shared.release(talk) }
        // Refused before any permission prompt or microphone: nothing is opened.
        let speech = SpeechService()
        await #expect(throws: (any Error).self) { try await speech.start(locale: "en-US", vocabulary: "", status: { _ in }) }
        do { try await speech.start(locale: "en-US", vocabulary: "", status: { _ in }) } catch {
            #expect(error.localizedDescription == "Talk is using the microphone. Dictation is back when Talk ends.")
        }
        #expect(!speech.isActive)
        let meeting = MeetingRecorder()
        var states: [String] = []
        meeting.onState = { _, _, message in states.append(message) }
        meeting.start(folder: FileManager.default.temporaryDirectory.appendingPathComponent("talk-meeting-\(UUID())"), inputUID: "")
        #expect(!meeting.recording && !meeting.working)
        #expect(states == ["Talk is using the microphone. Dictation is back when Talk ends."])
    }

    @Test func talkWaitsForADictationThatIsStillStarting() async throws {
        let speech = SpeechService()
        let permission = HeldPermission()
        speech.microphonePermission = { await permission.ask() }
        // Dictation is held at its permission prompt, before it opens any microphone: Talk must not take it now.
        let denied = Task { try await speech.start(locale: "en-US", vocabulary: "", status: { _ in }) }
        try await until { permission.isAsking }
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        await #expect(throws: TalkFailure(reason: .microphoneBusy)) { try await makeSession(transport, audio).start() }
        #expect(transport.connected.isEmpty && audio.started == 0)
        permission.answer(false)
        do { try await denied.value; Issue.record("A denied start should throw") } catch {
            #expect(error.localizedDescription.hasPrefix("Microphone access is off."))
        }

        // A start cancelled while it waits frees the microphone too.
        let cancelled = Task { try await speech.start(locale: "en-US", vocabulary: "", status: { _ in }) }
        try await until { permission.isAsking }
        await #expect(throws: TalkFailure(reason: .microphoneBusy)) { try await makeSession(ScriptedTransport(), FakeTalkAudio()).start() }
        cancelled.cancel()
        permission.answer(true)
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(!speech.isActive)

        let talk = makeSession(transport, audio)
        try await startListening(talk, transport)
        #expect(talk.state == .listening && audio.started == 1)
        talk.stop()
    }

    @Test func aDroppedSessionHangsUpAndFreesTheMicrophone() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        var session: TalkSession? = makeSession(transport, audio)
        var reports = 0
        session?.onUsage = { _ in reports += 1 }
        try await startListening(session!, transport)
        #expect(throws: (any Error).self) { try MicrophoneOwner.shared.requireFree() }
        session = nil
        try await until { transport.socket.isClosed }
        #expect(audio.stopped == 1 && reports == 1)
        try MicrophoneOwner.shared.requireFree()
    }

    @Test func openAIConversationTruncatesAfterABargeIn() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = TalkSession(configuration: TalkSessionConfiguration(provider: .openAIRealtime), apiKey: { "test-key-123" },
                                  transport: transport, audio: audio)
        var usage: TalkUsage?
        session.onUsage = { usage = $0 }
        let starting = Task { try await session.start() }
        try await until { transport.socket.sent.count == 1 }
        #expect(transport.socket.sent[0].hasPrefix(#"{"session":"#) && transport.socket.sent[0].contains(#""type":"session.update""#))
        #expect(transport.connected.first?.value(forHTTPHeaderField: "Authorization") == "Bearer " + "test-key-123")
        transport.socket.serverSends(#"{"type":"session.created","session":{}}"#)
        transport.socket.serverSends(#"{"type":"session.updated","session":{}}"#)
        try await starting.value
        #expect(session.state == .listening)
        #expect(audio.rates?.input == 24_000 && audio.rates?.output == 24_000)

        audio.speak(seconds: 0.25)
        try await until { transport.socket.sent.count == 2 }
        #expect(transport.socket.sent[1].hasPrefix(#"{"type":"input_audio_buffer.append""#))
        let speech = PCM16.encode([Float](repeating: 0.3, count: 24_000))
        transport.socket.serverSends(#"{"type":"response.output_audio.delta","item_id":"item_9","delta":""# + speech.base64EncodedString() + #""}"#)
        try await until { session.state == .modelSpeaking }
        audio.unplayed = 0.4
        transport.socket.serverSends(#"{"type":"input_audio_buffer.speech_started","audio_start_ms":500,"item_id":"item_10"}"#)
        try await until { transport.socket.sent.count == 3 }
        #expect(audio.flushed == 1 && session.state == .listening)
        #expect(transport.socket.sent[2] == #"{"audio_end_ms":600,"content_index":0,"item_id":"item_9","type":"conversation.item.truncate"}"#)
        transport.socket.serverSends(#"{"type":"response.done","response":{"status":"cancelled","usage":{"total_tokens":30,"input_tokens":20,"output_tokens":10}}}"#)
        try await until { session.usage.tokens != nil }
        session.stop()
        #expect(usage?.tokens == TalkTokenCounts(input: 20, output: 10, total: 30))
        #expect(abs((usage?.secondsSent ?? 0) - 0.25) < 0.001 && abs((usage?.secondsReceived ?? 0) - 1) < 0.001)
    }

    @Test func elapsedCountsWholeSeconds() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        let session = makeSession(transport, audio)
        try await startListening(session, transport)
        #expect(session.elapsed == .zero)
        try await until({ session.elapsed == .seconds(1) }, seconds: 3)
        session.stop()
    }

    @Test func voiceProcessingRetriesAStartThatRacesTheDevices() async throws {
        let transport = ScriptedTransport(), bench = EngineBench(failing: 1)
        let audio = bench.audio()
        let session = makeSession(transport, audio)
        var states: [TalkSession.State] = []
        let observer = session.$state.sink { states.append($0) }
        defer { observer.cancel() }
        try await startListening(session, transport)
        // The failed engine was torn down, the devices given time, and a fresh engine opened; the host saw only
        // connecting, then listening.
        #expect(bench.engines.count == 2 && bench.settles == [1])
        #expect(bench.engines[0].stopped == 1 && bench.engines[1].started == 1 && audio.openedOnAttempt == 2)
        #expect(states == [.idle, .connecting, .listening])
        bench.engines[1].speak(seconds: 0.5)
        try await until { transport.socket.sent.count == 2 }
        #expect(transport.socket.sent[1].contains(#""mimeType":"audio/pcm;rate=16000""#))

        // A configuration change the engine cannot resume from: a fresh engine, and the session keeps going.
        bench.engines[1].resumes = false
        bench.engines[1].configurationChange()
        try await until { bench.engines.count == 3 && bench.engines[2].started == 1 }
        #expect(bench.engines[1].stopped == 1 && session.state == .listening)
        bench.engines[2].speak(seconds: 0.5)
        try await until { transport.socket.sent.count == 3 }
        session.stop()
        #expect(bench.engines[2].stopped == 1)
        try MicrophoneOwner.shared.requireFree()
    }

    @Test func voiceProcessingGivesUpAfterTwoRetries() async throws {
        let transport = ScriptedTransport(), bench = EngineBench(failing: .max)
        let session = makeSession(transport, bench.audio())
        var reports = 0
        session.onUsage = { _ in reports += 1 }
        let starting = Task { try await session.start() }
        try await until { transport.socket.sent.count == 1 }
        transport.socket.serverSends(setupComplete)
        await #expect(throws: TalkFailure.self) { try await starting.value }
        guard case .ended(.audioFailed(let message)) = session.state else {
            Issue.record("Expected audioFailed, got \(session.state)"); return
        }
        #expect(message.contains("-10875"))
        #expect(bench.engines.count == VoiceProcessingTalkAudio.attempts && bench.settles == [1, 2])
        #expect(bench.engines.allSatisfy { $0.stopped >= 1 && $0.started == 0 })
        #expect(transport.socket.isClosed && reports == 1)
        try MicrophoneOwner.shared.requireFree()
    }

    @Test func aStopWhileTheDevicesSettleOpensNothingMore() async throws {
        let transport = ScriptedTransport(), bench = EngineBench(failing: 1)
        bench.holdSettles = true
        let session = makeSession(transport, bench.audio())
        let starting = Task { try await session.start() }
        try await until { transport.socket.sent.count == 1 }
        transport.socket.serverSends(setupComplete)
        try await until { bench.held != nil }
        #expect(session.state == .connecting)
        session.stop()
        bench.release()
        await #expect(throws: TalkFailure(reason: .stopped)) { try await starting.value }
        #expect(bench.engines.count == 1 && session.state == .ended(.stopped))
        try MicrophoneOwner.shared.requireFree()
    }

    @Test func theDurationCapStillAppliesWhileTheDevicesSettle() async throws {
        let transport = ScriptedTransport(), bench = EngineBench(failing: 1)
        bench.holdSettles = true
        let session = makeSession(transport, bench.audio(), cap: .milliseconds(300))
        let starting = Task { try await session.start() }
        try await until { transport.socket.sent.count == 1 }
        transport.socket.serverSends(setupComplete)
        try await until { bench.held != nil }
        try await until { !session.isRunning }
        bench.release()
        await #expect(throws: TalkFailure(reason: .durationCap)) { try await starting.value }
        #expect(bench.engines.count == 1)
        try MicrophoneOwner.shared.requireFree()
    }

    /// A host stops the session from its state observer. `@Published` hands that observer the ended state before it is
    /// stored, so the stop arrives while the session still looks running; it must not tear down or report twice.
    @Test func aHostThatStopsFromItsStateObserverEndsOnce() async throws {
        let transport = ScriptedTransport(), audio = FakeTalkAudio()
        audio.startError = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10875)
        let session = makeSession(transport, audio)
        var reports = 0
        session.onUsage = { _ in reports += 1 }
        var states: [TalkSession.State] = []
        let observer = session.$state.sink { state in
            states.append(state)
            if case .ended = state { session.stop() }
        }
        defer { observer.cancel() }
        let starting = Task { try await session.start() }
        try await until { transport.socket.sent.count == 1 }
        transport.socket.serverSends(setupComplete)
        await #expect(throws: TalkFailure.self) { try await starting.value }
        guard case .ended(.audioFailed(let message)) = session.state else {
            Issue.record("Expected audioFailed, got \(session.state)"); return
        }
        #expect(message.contains("-10875"))
        #expect(states.filter { if case .ended = $0 { true } else { false } }.count == 1)
        #expect(reports == 1 && audio.stopped == 1)
        try MicrophoneOwner.shared.requireFree()
    }
}
