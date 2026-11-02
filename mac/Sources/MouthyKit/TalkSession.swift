import Foundation
import MouthyCore
import MouthyNotch

/// Why a Talk session ended.
public enum TalkEndReason: Sendable, Equatable {
    /// The host called `stop()`.
    case stopped
    /// `maximumDuration` passed and the session hung up by itself.
    case durationCap
    /// The host's key closure threw or returned an empty key.
    case keyUnavailable(String)
    case microphoneDenied
    /// A dictation or meeting was recording in this app.
    case microphoneBusy
    /// The provider could not be reached or refused the session before it was ready.
    case connectionFailed(String)
    /// The provider closed a running session.
    case serverClosed(String)
    /// The microphone or speaker failed or changed.
    case audioFailed(String)
}

/// Thrown by `TalkSession.start()`; the session's state is `.ended(reason)` by then.
public struct TalkFailure: Error, Sendable, Equatable, LocalizedError {
    public let reason: TalkEndReason
    public init(reason: TalkEndReason) { self.reason = reason }
    public var errorDescription: String? {
        switch reason {
        case .stopped: return "Talk was stopped."
        case .durationCap: return "Talk reached its time limit."
        case .keyUnavailable(let message): return "The API key is unavailable: \(message)"
        case .microphoneDenied: return "Microphone access is off. Allow it in System Settings → Privacy & Security → Microphone."
        case .microphoneBusy: return MicrophoneOwner.busyMessage
        case .connectionFailed(let message), .serverClosed(let message), .audioFailed(let message): return message
        }
    }
}

/// A realtime voice conversation: the person speaks, the provider's model answers out loud. Mouthy owns the
/// microphone and speaker for the whole session (with echo cancellation), so dictation is unavailable until it ends.
///
/// The key is asked for once per `start()`, sent only in the connection's header, and never stored or logged.
/// A session runs once; make a new one to talk again.
@MainActor public final class TalkSession: ObservableObject {
    public enum State: Sendable, Equatable { case idle, connecting, listening, modelSpeaking, ended(TalkEndReason) }

    @Published public private(set) var state: State = .idle
    /// Both sides' words, when the provider sends them.
    @Published public private(set) var transcript: [TalkTurn] = []
    /// Whole seconds since the session started listening.
    @Published public private(set) var elapsed: Duration = .zero
    /// Muted: the microphone stays open (echo cancellation keeps running and the call stays live) but nothing it hears
    /// is sent, so the model hears nothing and no sent seconds are metered. The level meter reads 0 meanwhile.
    @Published public var isMuted = false
    /// Microphone and model loudness 0…1. Feeds, not published properties, so a level change redraws only the views
    /// that draw it (Mouthy's rule for live levels).
    public let inputLevel = VoiceLevelFeed()
    public let outputLevel = VoiceLevelFeed()
    /// Called once when a session that reached the provider ends, with everything it used.
    public var onUsage: (@MainActor (TalkUsage) -> Void)?
    /// Usage so far.
    public var usage: TalkUsage { meter.total }
    public let configuration: TalkSessionConfiguration

    private let apiKey: @Sendable () async throws -> String
    private let transport: any TalkTransport
    private let audio: any TalkAudio
    private var format: any TalkWireFormat
    private var meter: TalkUsageMeter
    private var words = TalkTranscript()
    private var socket: (any TalkSocket)?
    private var outgoing: AsyncStream<String>.Continuation?
    private var microphoneInput: AsyncStream<(Data, Float)>.Continuation?
    private var tasks: [Task<Void, Never>] = []
    private var ready: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var reachedProvider = false
    private var playing = false
    private var turnDone = true
    /// Set before `state` turns `.ended`: `@Published` hands the new state to observers before storing it, so a host
    /// that calls `stop()` from its state observer would otherwise run the teardown (and `onUsage`) a second time.
    private var ending = false
    /// How long `start()` waits for the provider to accept the setup.
    var setupTimeout: Duration = .seconds(15)

    public convenience init(configuration: TalkSessionConfiguration, apiKey: @escaping @Sendable () async throws -> String,
                            transport: any TalkTransport = URLSessionTalkTransport()) {
        self.init(configuration: configuration, apiKey: apiKey, transport: transport, audio: VoiceProcessingTalkAudio())
    }

    init(configuration: TalkSessionConfiguration, apiKey: @escaping @Sendable () async throws -> String,
         transport: any TalkTransport, audio: any TalkAudio) {
        self.configuration = configuration
        self.apiKey = apiKey; self.transport = transport; self.audio = audio
        format = configuration.provider.wireFormat(configuration)
        meter = TalkUsageMeter(provider: configuration.provider, model: configuration.model)
    }

    /// A session the host lets go of while running hangs up instead of keeping the connection open.
    isolated deinit {
        if isRunning { end(.stopped) }
    }

    public var isRunning: Bool {
        switch state { case .connecting, .listening, .modelSpeaking: return true; default: return false }
    }

    /// Connects, sends the setup, opens the microphone and returns once the model is listening. Throws `TalkFailure`
    /// (and ends the session) if any step fails or `stop()` is called first.
    public func start() async throws {
        guard state == .idle else { return }
        state = .connecting
        let cap = configuration.maximumDuration
        tasks.append(Task { [weak self] in
            do { try await Task.sleep(for: cap) } catch { return }
            self?.end(.durationCap)
        })
        do {
            try MicrophoneOwner.shared.claimForTalk(self)
        } catch {
            throw fail(.microphoneBusy)
        }
        let key: String
        do {
            key = try await apiKey().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw fail(.keyUnavailable(error.localizedDescription))
        }
        guard !key.isEmpty else { throw fail(.keyUnavailable("The key is empty.")) }
        try checkStillStarting()
        let socket: any TalkSocket
        do {
            socket = try await transport.connect(format.request(apiKey: key))
        } catch {
            throw fail(.connectionFailed(error.localizedDescription))
        }
        guard state == .connecting else { socket.close(); throw TalkFailure(reason: endReason ?? .stopped) }
        self.socket = socket
        reachedProvider = true
        Diagnostics.talk.notice("talk connected: \(self.configuration.provider.rawValue, privacy: .public) \(self.configuration.model, privacy: .public)")
        startSending(on: socket)
        startReceiving(from: socket)
        for message in format.openingMessages() { outgoing?.yield(message) }
        do {
            try await waitUntilReady()
        } catch let failure as TalkFailure {
            throw failure
        } catch {
            throw fail(.connectionFailed(error.localizedDescription))
        }
        try checkStillStarting()
        let microphone = AsyncStream<(Data, Float)>.makeStream(bufferingPolicy: .bufferingNewest(64))
        do {
            try await audio.start(inputRate: format.inputSampleRate, outputRate: format.outputSampleRate,
                                  input: { pcm, level in microphone.continuation.yield((pcm, level)) },
                                  playback: { [weak self] event in self?.handle(event) })
        } catch let failure as TalkFailure {
            throw fail(failure.reason)
        } catch {
            throw fail(.audioFailed(error.localizedDescription))
        }
        if let endReason {
            // Ended while the microphone was opening (a stop during the permission prompt): close it again.
            audio.stop(); microphone.continuation.finish()
            throw TalkFailure(reason: endReason)
        }
        microphoneInput = microphone.continuation
        tasks.append(Task { [weak self] in
            for await (pcm, level) in microphone.stream { self?.sendMicrophone(pcm, level: level) }
        })
        state = .listening
        startClock()
    }

    /// Hangs up. Safe to call at any time; usage is reported once.
    public func stop() { end(.stopped) }

    // MARK: Connection

    private var endReason: TalkEndReason? {
        if case .ended(let reason) = state { return reason }
        return nil
    }

    private func checkStillStarting() throws {
        if let endReason { throw TalkFailure(reason: endReason) }
    }

    private func fail(_ reason: TalkEndReason) -> TalkFailure {
        end(reason)
        return TalkFailure(reason: endReason ?? reason)
    }

    private func startSending(on socket: any TalkSocket) {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        outgoing = continuation
        tasks.append(Task { [weak self] in
            for await message in stream {
                do { try await socket.send(message) } catch {
                    self?.connectionLost(error)
                    return
                }
            }
        })
    }

    /// Holds the session only while handling a message, so a session the host let go of can still be released.
    private func startReceiving(from socket: any TalkSocket) {
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                let message: String
                do { message = try await socket.receive() } catch {
                    self?.connectionLost(error)
                    return
                }
                guard let self, !Task.isCancelled, self.isRunning else { return }
                for event in self.format.read(message) { self.handle(event) }
            }
        })
    }

    private func connectionLost(_ error: Error) {
        guard isRunning else { return }
        let message = (error as? TalkSocketClosed).map { $0.reason.isEmpty ? "The provider closed the connection (\($0.code))." : $0.reason }
            ?? error.localizedDescription
        end(state == .connecting ? .connectionFailed(message) : .serverClosed(message))
    }

    private func waitUntilReady() async throws {
        let timeout = setupTimeout
        let timer = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            self?.end(.connectionFailed("The provider did not accept the session in time."))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let endReason { continuation.resume(throwing: TalkFailure(reason: endReason)) }
            else if isReady { continuation.resume() }
            else { ready = continuation }
        }
    }

    // MARK: Events

    private func handle(_ event: TalkEvent) {
        switch event {
        case .ready:
            isReady = true
            ready?.resume(); ready = nil
        case .audio(let pcm):
            guard state == .listening || state == .modelSpeaking else { return }
            meter.received(bytes: pcm.count, sampleRate: format.outputSampleRate)
            turnDone = false; playing = true
            state = .modelSpeaking
            audio.play(pcm, level: PCM16.level(pcm))
        case .transcript(let role, let text):
            words.append(text, from: role); transcript = words.turns
        case .transcriptFinished(let role):
            words.complete(role); transcript = words.turns
        case .interrupted:
            // Barge-in: the person spoke over the model. Drop its queued speech at once, then tell a provider that
            // keeps the conversation by what it sent how much was heard.
            let unplayed = audio.flush()
            for message in format.interruptionMessages(unplayedSeconds: unplayed) { outgoing?.yield(message) }
            playing = false; turnDone = true
            meter.endTurn()
            words.complete(.model); transcript = words.turns
            outputLevel.send(0)
            if state == .modelSpeaking { state = .listening }
        case .turnComplete:
            turnDone = true
            meter.endTurn()
            words.completeAll(); transcript = words.turns
            if !playing, state == .modelSpeaking { state = .listening }
        case .usage(let counts):
            meter.report(counts)
        case .closing(let message), .notice(let message):
            Diagnostics.talk.notice("talk: \(message, privacy: .public)")
        case .failure(let message):
            end(state == .connecting ? .connectionFailed(message) : .serverClosed(message))
        }
    }

    private func handle(_ event: TalkPlayback) {
        switch event {
        case .level(let level):
            outputLevel.send(level)
        case .drained:
            playing = false
            if turnDone, state == .modelSpeaking { state = .listening }
        case .failed(let message):
            end(.audioFailed(message))
        }
    }

    private func sendMicrophone(_ pcm: Data, level: Float) {
        guard state == .listening || state == .modelSpeaking else { return }
        if isMuted { inputLevel.send(0); return }
        meter.sent(bytes: pcm.count, sampleRate: format.inputSampleRate)
        inputLevel.send(level)
        outgoing?.yield(format.audioMessage(pcm))
    }

    // MARK: Clock and ending

    private func startClock() {
        let started = ContinuousClock.now
        tasks.append(Task { [weak self] in
            var seconds = 0
            while true {
                seconds += 1
                do { try await Task.sleep(until: started + .seconds(seconds), clock: .continuous) } catch { return }
                guard let self, self.isRunning else { return }
                self.elapsed = .seconds(seconds)
            }
        })
    }

    private func end(_ reason: TalkEndReason) {
        guard !ending, isRunning || state == .idle else { return }
        ending = true
        state = .ended(reason)
        Diagnostics.talk.notice("talk ended: \(String(describing: reason), privacy: .public)")
        for task in tasks { task.cancel() }
        tasks = []
        outgoing?.finish(); outgoing = nil
        microphoneInput?.finish(); microphoneInput = nil
        audio.stop()
        socket?.close(); socket = nil
        MicrophoneOwner.shared.release(self)
        ready?.resume(throwing: TalkFailure(reason: reason)); ready = nil
        playing = false
        inputLevel.send(0); outputLevel.send(0)
        words.completeAll(); transcript = words.turns
        if reachedProvider { onUsage?(meter.total) }
    }
}
