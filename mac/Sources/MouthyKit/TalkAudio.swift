import AVFoundation
import Foundation
import MouthyCore

/// What playback reports back to the session.
enum TalkPlayback: Sendable, Equatable {
    /// Loudness of the speech playing now (0 when nothing plays).
    case level(Float)
    /// Everything queued has played.
    case drained
    /// The microphone or speaker went away; the session ends.
    case failed(String)
}

/// Talk's microphone and speaker. The real one is `VoiceProcessingTalkAudio`; tests pass a fake.
@MainActor protocol TalkAudio: AnyObject {
    /// Opens the microphone and speaker. `input` receives 16-bit mono PCM at `inputRate` and its level, on the audio
    /// thread, in order.
    func start(inputRate: Double, outputRate: Double, input: @escaping @Sendable (Data, Float) -> Void,
               playback: @escaping @MainActor (TalkPlayback) -> Void) async throws
    /// Queues model speech (16-bit mono PCM at `outputRate`).
    func play(_ pcm16: Data, level: Float)
    /// Barge-in: stops playback at once and drops everything queued. Returns how much speech went unheard (the
    /// buffer playing counts whole, so this errs on the side of less heard).
    @discardableResult func flush() -> Double
    func stop()
}

/// One AVAudioEngine's worth of voice-processing I/O. `VoiceProcessingTalkAudio` builds a fresh one for every try at
/// opening the devices; tests pass fakes.
@MainActor protocol TalkAudioEngine: AnyObject {
    /// Turns voice processing on, wires the player (fed at `outputRate`) and a microphone tap made by `tap` for the
    /// microphone's format, and starts. Returns that format. `configurationChanged` runs on the main actor when macOS
    /// reconfigures the devices.
    func start(outputRate: Double, tap: (AVAudioFormat) -> @Sendable (AVAudioPCMBuffer) -> Void,
               configurationChanged: @escaping @MainActor @Sendable () -> Void) throws -> AVAudioFormat
    /// After a configuration change: starts again if the microphone format held. False if it did not.
    func resume() -> Bool
    /// Queues speech; `played` runs (on any thread) once it has been heard.
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void)
    /// Drops every queued buffer at once and readies the player for the next one.
    func flushPlayer()
    /// Stops, removes the tap and turns voice processing off. Safe on an engine that never started.
    func stop()
}

/// Voice-processing I/O with retries: opening it reconfigures the devices underneath, and Core Audio can fail a start
/// that races that reconfiguration (a host's 2026-10-14 log, see the Talk ADR). A failed start tears down only that
/// engine, waits for the devices to settle and tries again on a fresh one, at most `attempts` times; a configuration
/// change the running engine cannot resume from is handled the same way. The session stays `.connecting` meanwhile.
@MainActor final class VoiceProcessingTalkAudio: TalkAudio {
    /// One start and two retries.
    static let attempts = 3
    private let makeEngine: @MainActor () -> any TalkAudioEngine
    /// Waits before retry `n` (1, 2): 300 ms, then 600 ms, 0.9 s in all.
    private let settle: @MainActor (Int) async -> Void
    private let permission: @MainActor () async -> Bool
    private var engine: (any TalkAudioEngine)?
    private var playFormat: AVAudioFormat?
    private var input: (@Sendable (Data, Float) -> Void)?
    private var inputRate = 0.0
    private var playback: (@MainActor (TalkPlayback) -> Void)?
    /// Level and length of each buffer not yet played, oldest first.
    private var queued: [(level: Float, seconds: Double)] = []
    /// Bumped by `flush` and `stop`, so completions of dropped buffers are ignored.
    private var epoch = 0
    /// Bumped by `stop`, so a retry still waiting for the devices to settle gives up.
    private var run = 0
    /// Which try opened the running engine (1 = the first).
    private(set) var openedOnAttempt = 0

    init(makeEngine: @escaping @MainActor () -> any TalkAudioEngine = { AVTalkAudioEngine() },
         settle: @escaping @MainActor (Int) async -> Void = { try? await Task.sleep(for: .milliseconds(300 * $0)) },
         permission: @escaping @MainActor () async -> Bool = { await MicrophonePermission.request() }) {
        self.makeEngine = makeEngine; self.settle = settle; self.permission = permission
    }

    func start(inputRate: Double, outputRate: Double, input: @escaping @Sendable (Data, Float) -> Void,
               playback: @escaping @MainActor (TalkPlayback) -> Void) async throws {
        guard await permission() else {
            throw TalkFailure(reason: .microphoneDenied)
        }
        guard let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false) else {
            throw MouthyFailure("No working speaker was found.")
        }
        run += 1
        self.inputRate = inputRate; self.input = input; self.playback = playback; self.playFormat = playFormat
        do {
            try await open(run: run)
        } catch {
            stop()
            throw error
        }
    }

    /// Builds and starts a fresh engine, retrying after the devices settle.
    private func open(run: Int) async throws {
        var failure: Error = MouthyFailure("No working microphone was found.")
        for attempt in 1...Self.attempts {
            if attempt > 1 {
                await settle(attempt - 1)
                guard run == self.run else { throw CancellationError() }
            }
            guard let playFormat, let input else { throw CancellationError() }
            let engine = makeEngine()
            do {
                let rate = inputRate
                let format = try engine.start(outputRate: playFormat.sampleRate, tap: { format in
                    // Made for this engine's microphone format, which can differ after a device change.
                    let converter = TalkInputConverter(from: format, toRate: rate)
                    return { buffer in
                        guard let (pcm, level) = converter.convert(buffer) else { return }
                        input(pcm, level)
                    }
                }, configurationChanged: { [weak self, weak engine] in
                    guard let self, let engine, self.engine === engine else { return }
                    self.configurationChanged(engine)
                })
                self.engine = engine
                openedOnAttempt = attempt
                Diagnostics.talk.notice("talk audio started: \(Int(format.sampleRate), privacy: .public) Hz, \(format.channelCount, privacy: .public) ch, voice processing on, attempt \(attempt, privacy: .public)")
                return
            } catch {
                engine.stop()
                failure = error
                let code = (error as NSError).code
                Diagnostics.talk.notice("talk audio: attempt \(attempt, privacy: .public) of \(Self.attempts, privacy: .public) failed (\((error as NSError).domain, privacy: .public) \(code, privacy: .public))")
            }
        }
        throw failure
    }

    /// macOS can report a configuration change (and stop the engine) when voice processing settles or a device
    /// changes. Same microphone format: start again and keep talking. Otherwise build a fresh engine for the new
    /// devices; only if that fails too does the session end.
    private func configurationChanged(_ changed: any TalkAudioEngine) {
        if changed.resume() {
            // The stop dropped whatever was queued; start the player clean.
            flush()
            Diagnostics.talk.notice("talk audio: configuration changed, resumed")
            return
        }
        Diagnostics.talk.notice("talk audio: configuration changed, reopening")
        changed.stop()
        engine = nil
        dropQueue()
        let run = self.run
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.open(run: run)
            } catch {
                guard run == self.run else { return }
                self.playback?(.failed("The microphone or speaker changed, so Talk ended."))
            }
        }
    }

    func play(_ pcm16: Data, level: Float) {
        // No engine while one is being rebuilt: the speech is lost, and saying so keeps the session from waiting on it.
        guard let engine, let playFormat else { playback?(.drained); return }
        let samples = PCM16.decode(pcm16)
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        queued.append((level, Double(samples.count) / playFormat.sampleRate))
        if queued.count == 1 { playback?(.level(level)) }
        let epoch = self.epoch
        engine.schedule(buffer) { [weak self] in
            Task { @MainActor in self?.played(epoch) }
        }
    }

    private func played(_ epoch: Int) {
        guard epoch == self.epoch, !queued.isEmpty else { return }
        queued.removeFirst()
        if let next = queued.first {
            playback?(.level(next.level))
        } else {
            playback?(.level(0)); playback?(.drained)
        }
    }

    @discardableResult func flush() -> Double {
        let unplayed = queued.reduce(0) { $0 + $1.seconds }
        dropQueue()
        engine?.flushPlayer()
        return unplayed
    }

    private func dropQueue() {
        epoch += 1
        let hadQueued = !queued.isEmpty
        queued.removeAll()
        if hadQueued { playback?(.level(0)); playback?(.drained) }
    }

    func stop() {
        epoch += 1; run += 1
        queued.removeAll()
        engine?.stop()
        engine = nil; playFormat = nil; input = nil; playback = nil
    }
}

/// The real engine: records from the system input and plays to the system output through one AVAudioEngine with
/// voice processing, so its echo cancellation removes the model's own voice from the microphone and the provider hears
/// only the person. Stopping releases both and ends the voice processing (and the ducking of other audio macOS applies
/// while it runs).
@MainActor final class AVTalkAudioEngine: TalkAudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private var tapped = false
    private var observer: NSObjectProtocol?

    func start(outputRate: Double, tap: (AVAudioFormat) -> @Sendable (AVAudioPCMBuffer) -> Void,
               configurationChanged: @escaping @MainActor @Sendable () -> Void) throws -> AVAudioFormat {
        // Voice processing goes on first, through the output node: enabling it on either I/O node enables it on both
        // (AVAudioIONode.h). Touching `inputNode` first made the engine build its own default input+output aggregate,
        // which voice processing then reconfigured underneath it. The input node is the fallback (the old order).
        do { try engine.outputNode.setVoiceProcessingEnabled(true) } catch { try engine.inputNode.setVoiceProcessingEnabled(true) }
        let microphone = engine.inputNode
        let format = microphone.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate, channels: 1, interleaved: false) else {
            throw MouthyFailure("No working microphone was found.")
        }
        // "The output format of the input node and the input format of the output node have to be the same"
        // (AVAudioIONode.h). Left alone, the engine connects its mixer to the output in the speaker's hardware format,
        // and voice processing refuses to initialize: -10875, "client-side input and output formats do not match".
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playFormat)
        let deliver = tap(format)
        // About 40 ms per message, inside the 20-100 ms Google recommends; macOS may deliver larger buffers.
        try AudioCompat.installTap(on: microphone, bufferSize: AVAudioFrameCount(format.sampleRate / 25), format: format) { buffer, _ in
            deliver(buffer)
        }
        tapped = true
        self.format = format
        // Observed before the start, so a change while it starts is not missed.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
            MainActor.assumeIsolated { configurationChanged() }
        }
        engine.prepare()
        try engine.start()
        player.play()
        return format
    }

    func resume() -> Bool {
        guard let format, engine.inputNode.outputFormat(forBus: 0).isEqual(format), (try? engine.start()) != nil else { return false }
        return true
    }

    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @Sendable () -> Void) {
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in played() }
    }

    func flushPlayer() {
        // stop() drops every scheduled buffer immediately; play() readies the node for the next answer.
        player.stop(); player.play()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        player.stop()
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        // Off on either node turns it off on both; the output node never builds an input aggregate of its own.
        try? engine.outputNode.setVoiceProcessingEnabled(false)
    }
}

/// Turns microphone buffers into 16-bit mono PCM at the provider's rate. Used only on the audio tap's thread.
final class TalkInputConverter: @unchecked Sendable {
    private let source: AVAudioFormat
    private let mono: AVAudioFormat
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(from source: AVAudioFormat, toRate rate: Double) {
        self.source = source
        mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.sampleRate, channels: 1, interleaved: false)!
        target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        converter = AVAudioConverter(from: mono, to: target)
    }

    /// Voice processing can hand over several channels; the first is the processed (echo-cancelled) voice.
    func convert(_ buffer: AVAudioPCMBuffer) -> (Data, Float)? {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0, let converter,
              let first = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength) else { return nil }
        let frames = Int(buffer.frameLength)
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let out = first.floatChannelData![0]
        for index in 0..<frames { out[index] = data[0][index * stride] }
        first.frameLength = buffer.frameLength
        let level = MicrophoneFrame.measure(UnsafeBufferPointer(start: out, count: frames)).level
        let capacity = AVAudioFrameCount(ceil(Double(frames) * target.sampleRate / mono.sampleRate) + 64)
        guard let resampled = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: resampled, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true; inputStatus.pointee = .haveData; return first
        }
        guard error == nil, status != .error, resampled.frameLength > 0, let samples = resampled.floatChannelData?[0] else { return nil }
        return (PCM16.encode(UnsafeBufferPointer(start: samples, count: Int(resampled.frameLength))), level)
    }
}
