import FluidAudio
import Foundation
import MouthyCore

/// Times stop-to-text: a recording is replayed into `LiveTranscriber` at real-time speed, like a microphone, and
/// the person double-taps the shortcut (or presses it once) `stopDelay` ms after their last word. `Mouthy bench-live file.wav` runs it
/// on any Mac.
@MainActor
enum LiveBenchmark {
    /// `release`: one key press (or a hold-to-talk release) instead of the double tap. `waited`: ms the stop waited for
    /// audio still in flight from the device; `milliseconds` is recognition alone. `cpu`: seconds of process CPU the
    /// whole dictation used (getrusage, every background pass and the stop), over `seconds` of recording.
    struct Run { let stopDelay: Int; let release: Bool; let waited: Int; let milliseconds: Int; let text: String; let cpu: Double; let seconds: Double }
    struct Result { let wholeMilliseconds: Int; let whole: String; let runs: [Run] }
    /// How far the device's audio trails the moment the person presses stop (71-162 ms measured on an M5).
    static let inFlight = 160

    static func run(file: URL, engine: SpeechEngine = .parakeet, vocabulary: String = "", stopDelays: [Int] = [0, 200],
                    releaseDelays: [Int] = [0]) async throws -> Result {
        let audio = try AudioConverter().resampleAudioFile(file)
        let decode: LiveTranscriber.Decode = { samples, boost in
            if engine == .whisper {
                let samples = await VoiceActivity.shared.voiceOnly(samples) ?? samples
                guard !samples.isEmpty else { return "" }
                return try await WhisperRecognizer.shared.transcribe(samples: samples, model: .baseEnglish, language: "auto", translate: false, vocabulary: "").text
            }
            return try await ParakeetRecognizer.shared.transcribe(samples: samples, boost: boost)
        }
        let decodeAfter = engine == .parakeet ? ParakeetRecognizer.decodeAfter : nil
        if engine == .whisper {
            try await WhisperRecognizer.shared.prepare(model: .baseEnglish, download: false) { _ in }
        } else {
            await ParakeetRecognizer.shared.setVocabulary(vocabulary)
            try await ParakeetRecognizer.shared.prepare(download: false) { _ in }
        }
        _ = try await decode(Array(audio.prefix(32_000)), true)   // warm, as Mouthy is after launch
        await VoiceActivity.shared.prepare()
        var started = ContinuousClock.now
        let whole = try await decode(audio, true)
        let wholeMilliseconds = milliseconds(since: started)
        var runs: [Run] = []
        for (stopDelay, release) in stopDelays.map({ ($0, false) }) + releaseDelays.map({ ($0, true) }) {
            // The microphone keeps recording (silence) and hears the key clicks. Double tap (Right Command): the first
            // `stopDelay` ms after the last word, the second 150 ms later, which stops the dictation; by then the device
            // has delivered the audio up to the first. Single press: one click that stops at once, while the newest
            // `inFlight` ms are still on their way. Like SpeechService.finish(cutAt:), recognition gets the audio up
            // to where the stopping key began; the background passes heard the clicks too.
            let first = audio.count + stopDelay * 16, second = first + 2_400
            let clicks = release ? [first] : [first, second]
            var mic = audio + [Float](repeating: 0, count: (clicks.last ?? first) + 320 - audio.count)
            for click in clicks {
                for i in 0..<320 { mic[click + i] = (i % 2 == 0 ? 0.3 : -0.3) * Float(320 - i) / 320 }
            }
            let delivered = release ? max(0, first - inFlight * 16) : mic.count
            var recorded = 0
            let cpu = cpuSeconds()
            let live = LiveTranscriber(decode: decode, decodeAfter: decodeAfter, hearsSpeech: VoiceActivity.hearsSpeech, count: { recorded },
                                       read: { Array(mic[$0.clamped(to: 0..<recorded)]) })
            while recorded < delivered {
                let step = min(delivered - recorded, 1_600)
                recorded += step
                live.tick()
                try await Task.sleep(for: .milliseconds(step / 16))
            }
            // The stop waits for the audio still in flight only when the newest audio might be words running into it.
            var waited = 0
            if recorded < first, live.soundsAtEnd() {
                waited = (first - recorded) / 16
                try await Task.sleep(for: .milliseconds(waited))
                recorded = first
            }
            started = ContinuousClock.now
            let text = try await live.finish(Array(mic[..<min(first, recorded)]))
            let elapsed = milliseconds(since: started)
            runs.append(Run(stopDelay: stopDelay, release: release, waited: waited, milliseconds: elapsed, text: text,
                            cpu: cpuSeconds() - cpu, seconds: Double(recorded) / 16_000))
        }
        return Result(wholeMilliseconds: wholeMilliseconds, whole: whole, runs: runs)
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = usage.ru_utime.tv_sec + usage.ru_stime.tv_sec, micros = usage.ru_utime.tv_usec + usage.ru_stime.tv_usec
        return Double(seconds) + Double(micros) / 1e6
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = start.duration(to: .now)
        return Int(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
}
