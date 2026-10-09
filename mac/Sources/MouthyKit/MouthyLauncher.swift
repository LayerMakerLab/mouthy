import Foundation
import Speech
import Darwin
import AppKit
import MouthyCore

public enum MouthyLauncher {
    @MainActor public static func main() async {
        do {
            let command = try MouthyCommand.parse(Array(CommandLine.arguments.dropFirst()))
            if case let .application(headless, _) = command {
                let me = ProcessInfo.processInfo.processIdentifier
                let ownID = Bundle.main.bundleIdentifier ?? "dev.mouthy.Mouthy"
                // Mouthy and Mouthy Dev share the shortcut, Enter tap and agent port: only one may run.
                // Launching one variant quits the other.
                for variant in ["dev.mouthy.Mouthy", "dev.mouthy.Mouthy.dev"] where variant != ownID {
                    for app in NSRunningApplication.runningApplications(withBundleIdentifier: variant) {
                        app.terminate()
                        for _ in 0..<40 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(50)) }
                        if !app.isTerminated { app.forceTerminate() }
                    }
                }
                let other = NSRunningApplication.runningApplications(withBundleIdentifier: ownID).contains { $0.processIdentifier != me }
                if other {
                    guard !headless else { throw MouthyFailure("Mouthy is already running. Use --open for its settings.") }
                    // Finder/Dock launches have no --open argument. Surface the running
                    // instance rather than failing invisibly when another copy owns input.
                    DistributedNotificationCenter.default().postNotificationName(.init("dev.mouthy.Mouthy.open"), object: nil,
                        userInfo: ["requestedBundlePath": Bundle.main.bundleURL.standardizedFileURL.path], deliverImmediately: true)
                    return
                }
                // Headless runs promise no windows, so only the full app checks for updates.
                if !headless { AppUpdater.startAfterLaunch() }
                MouthyApp.main(); return
            }
            // Third-party diagnostics go to stderr; stdout remains machine-readable.
            let savedOutput = dup(STDOUT_FILENO)
            guard savedOutput >= 0 else { throw MouthyFailure("Cannot open command output.") }
            let stdout = FileHandle(fileDescriptor: savedOutput, closeOnDealloc: true)
            fflush(nil); dup2(STDERR_FILENO, STDOUT_FILENO)
            try await execute(command, stdout: stdout)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(("Mouthy: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
    @MainActor private static func execute(_ command: MouthyCommand, stdout: FileHandle) async throws {
        switch command {
        case .help:
            stdout.write(Data("""
            Mouthy — local dictation and headless transcription

            Mouthy                          Background app with optional notch and menu bar
            Mouthy --open                   Open the main window
            Mouthy --headless               Background shortcut dictation, no windows or menu
            Mouthy models                   List cached local models
            Mouthy download parakeet
            Mouthy download whisper --model base.en|small|medium|turbo
            Mouthy transcribe AUDIO... [options]

            --engine apple|parakeet|whisper  Default: apple
            --model base.en|small|medium|turbo Whisper model; download explicitly first
            --language auto|en|en-US|...     Apple auto uses en-US; Whisper can detect language
            --prompt TEXT                   Vocabulary/spelling hints
            --translate                     Whisper Small/Medium to English
            --format text|json|srt|vtt       Default: text
            --output FILE                   Write a new file; never overwrite
            --output-dir DIRECTORY          Sequential batch output; required for multiple inputs

            Inference uses cached models. Downloads happen only through explicit setup.
            CLI imports do not enter history or insert into apps. Ctrl-C stops the command.
            \n
            """.utf8))
        case .models:
            let state: [String: Any] = ["parakeet": ParakeetRecognizer.installed,
                "whisper": Dictionary(uniqueKeysWithValues: WhisperModel.allCases.map { ($0.rawValue, WhisperRecognizer.installed($0)) })]
            stdout.write(try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])); stdout.write(Data("\n".utf8))
        case let .benchLive(path, engine):
            let result = try await LiveBenchmark.run(file: URL(fileURLWithPath: path), engine: engine)
            var lines = ["recognize after stop: \(result.wholeMilliseconds) ms"]
            lines += result.runs.map {
                "live, \($0.release ? "single press" : "double tap") \($0.stopDelay) ms after last word: \($0.milliseconds) ms"
                    + ($0.waited > 0 ? " (after \($0.waited) ms for audio in flight)" : "")
                    + String(format: "\ndictation CPU: %.1f s over %.1f s of recording (%.2f cores)", $0.cpu, $0.seconds, $0.cpu / max($0.seconds, 0.1))
                    + "\ntext: " + $0.text
            }
            lines += ["whole: " + result.whole]
            stdout.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        case let .micTest(seconds, engine):
            // Hardware check: record from the default microphone, then print what was heard.
            let speech = SpeechService()
            let started = Date()
            let locale = Locale.current.identifier(.bcp47)
            try await speech.start(locale: SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }.contains(locale) ? locale : "en-US",
                                   vocabulary: "", provider: engine, whisperModel: .baseEnglish) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            FileHandle.standardError.write(Data("Listening for \(seconds) s on \(speech.inputDeviceName) (\(engine.label), ready in \(String(format: "%.2f", Date().timeIntervalSince(started))) s)…\n".utf8))
            try await Task.sleep(for: .seconds(seconds))
            let stop = Date()
            let text = try await speech.finish()
            stdout.write(Data((text + "\n").utf8))
            FileHandle.standardError.write(Data("Transcribed in \(String(format: "%.2f", Date().timeIntervalSince(stop))) s.\n".utf8))
        case let .download(engine, model):
            if let saved = try? LocalStore().load("preferences.json", as: Preferences.self), saved.localOnly {
                throw MouthyFailure("Network use is blocked. Allow it in Mouthy settings to download models.")
            }
            let progress: @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            if engine == .parakeet { try await ParakeetRecognizer.shared.prepare(download: true, progress: progress) }
            else { try await WhisperRecognizer.shared.prepare(model: model, download: true, progress: progress) }
            stdout.write(Data("Model ready for offline transcription.\n".utf8))
            await ParakeetRecognizer.shared.releaseIfIdle(); await WhisperRecognizer.shared.releaseIfIdle()
        case let .transcribe(options):
            let urls = options.inputs.map { URL(fileURLWithPath: $0).standardizedFileURL }
            let destinations: [URL?] = urls.map { input in
                if let path = options.output { return URL(fileURLWithPath: path).standardizedFileURL }
                return options.outputDirectory.map { URL(fileURLWithPath: $0).appendingPathComponent(input.deletingPathExtension().lastPathComponent + "." + options.format.fileExtension).standardizedFileURL }
            }
            let outputs = destinations.compactMap { $0 }
            guard Set(outputs).count == outputs.count else { throw MouthyFailure("Batch filenames collide. Use distinct input filenames.") }
            for (index, input) in urls.enumerated() {
                guard FileManager.default.fileExists(atPath: input.path) else { throw MouthyFailure("Input does not exist: \(input.lastPathComponent)") }
                if let output = destinations[index], FileManager.default.fileExists(atPath: output.path) {
                    throw MouthyFailure("Output already exists: \(output.lastPathComponent). Choose a new name.")
                }
            }
            if let path = options.outputDirectory { try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let speech = SpeechService()
            for (index, input) in urls.enumerated() {
                try Task.checkCancellation()
                let prepared = try await MediaInput.prepare(input)
                defer { prepared.removeTemporary() }
                _ = try await speech.transcribeFile(prepared.url, locale: options.language == "auto" ? "en-US" : options.language,
                    vocabulary: options.prompt, provider: options.engine, whisperModel: options.model,
                    whisperLanguage: options.language, translate: options.translate, status: { _ in })
                let data = try speech.document.exported(as: options.format)
                if let destination = destinations[index] {
                    try data.write(to: destination, options: .withoutOverwriting)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                } else { stdout.write(data) }
            }
            await ParakeetRecognizer.shared.releaseIfIdle(); await WhisperRecognizer.shared.releaseIfIdle()
        case .application: break
        }
    }
}
