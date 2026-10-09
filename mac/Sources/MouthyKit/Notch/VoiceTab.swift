import AppKit
import MouthyCore
import MouthyNotch
import SwiftUI

/// Mouthy in the notch: start dictation into the app you were using, and copy recent results.
/// Only registered by the Mouthy app itself; hosts bring their own dictation.
@MainActor final class VoiceTab: NotchTab {
    static let shared = VoiceTab()
    let id = "mouthy.voice"
    let title = "Mouthy"
    let symbolName = "waveform"
    func makeBody() -> AnyView { AnyView(VoiceTabView(model: AppModel.shared, recent: RecentResults.shared)) }
}

struct VoiceTabView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var recent: RecentResults

    /// Recent results: this session's (memory only), else saved history.
    static func recentTexts(session: [String], history: [MouthyCore.Transcript], limit: Int = 8) -> [String] {
        Array((session.isEmpty ? history.map(\.text) : session).prefix(limit))
    }

    /// Paste last has something to paste.
    static func canPasteLast(output: String, history: [MouthyCore.Transcript]) -> Bool { !output.isEmpty || !history.isEmpty }

    var body: some View {
        let listening = model.phase == .listening
        let dictating = [.preparing, .listening, .finishing, .delivering].contains(model.phase)
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 6) {
                Button {
                    // The hub never becomes the frontmost app, so the words go where you were typing; it stays open
                    // and shows them here.
                    model.toggle(captureTarget: true, fromNotch: true)
                } label: {
                    MicButton(listening: listening, finishing: dictating && !listening)
                }
                .buttonStyle(NotchPressStyle())
                .disabled(dictating && !listening)
                .help(listening ? "Finish dictation" : "Dictate into the app you were using")
                .accessibilityLabel(listening ? "Finish dictation" : "Start dictation")
                if !dictating, Self.canPasteLast(output: model.output, history: model.history) {
                    PillButton(title: "Paste", symbol: "doc.on.clipboard") {
                        NotchHub.shared.setOpenFromHost(false)
                        model.pasteLast()
                    }
                    .help("Paste the last result (⌃⌘V)")
                }
            }
            .frame(width: 96)
            if dictating {
                LiveDictation(model: model)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 20) {
                        VoiceStat(value: model.stats.words, label: VoiceStat.noun("word", model.stats.words))
                        VoiceStat(value: model.stats.sessions, label: VoiceStat.noun("dictation", model.stats.sessions))
                        VoiceStat(value: model.stats.minutesSaved, label: "min saved")
                    }
                    let outcome = DictationOutcome.from(status: model.status, failed: model.phase == .failed, target: model.targetName)
                    if outcome.kind == .attention {
                        // What the band's ember dot meant, in words.
                        HStack(spacing: 7) {
                            Circle().fill(MouthyTheme.ember).frame(width: 6, height: 6)
                            Text(outcome.text).font(.system(size: 13, weight: .medium)).foregroundStyle(MouthyTheme.cream)
                        }
                    }
                    TeachRow(model: model)
                    // The last result, one click to copy; the full list lives in Mouthy's History.
                    if let last = Self.recentTexts(session: recent.items, history: model.history, limit: 1).first {
                        RecentRow(text: last)
                    } else {
                        Text("Press your shortcut or the mic and start talking.").font(.system(size: 13)).foregroundStyle(MouthyTheme.cream2)
                    }
                }
            }
        }
    }
}

/// The dictation running now, bigger than the band can show it: where the words go, the time, an agent's question
/// and the live words.
struct LiveDictation: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let finishing = model.phase != .listening && model.phase != .preparing
        let question = model.agentQuestion?.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = model.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                MouthyWaveform(level: 0, active: !finishing, bars: 5, height: 14, barWidth: 2.5, sweep: finishing, feed: model.voice)
                    .frame(width: 24, height: 16)
                Text(Self.targetLine(model.targetName))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(MouthyTheme.cream2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                ElapsedTimeView(clock: model.clock) { elapsed in
                    Text(Self.clock(elapsed))
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(MouthyTheme.cream2)
                }
                Button { model.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(MouthyTheme.cream2)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(MouthyTheme.cream.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Cancel (Esc)")
                .accessibilityLabel("Cancel dictation")
            }
            if let question, !question.isEmpty {
                Text(question)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MouthyTheme.cream)
                    .lineLimit(3)
            }
            Text(words.isEmpty ? " " : words)
                .font(.system(size: 15))
                .foregroundStyle(MouthyTheme.cream)
                .lineLimit(3).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// "Into Notes", or nothing to name when the words stay in Mouthy.
    static func targetLine(_ target: String) -> String {
        let name = target.trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name == "Mouthy workspace" ? "Mouthy" : "Into " + name
    }

    /// Elapsed time as m:ss.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }
}

struct RecentRow: View {
    let text: String
    @State private var hovering = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            NotchHub.shared.presentResult("Copied", ok: true)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(text).font(.system(size: 14)).foregroundStyle(MouthyTheme.cream).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "doc.on.doc").font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(MouthyTheme.glow).opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .hoverRow()
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click to copy")
    }
}

/// The mic: a quiet round button. Listening, it turns warm and becomes the stop button; nothing pulses.
struct MicButton: View {
    let listening: Bool
    var finishing = false
    @State private var hovering = false
    var body: some View {
        ZStack {
            Circle().fill(listening ? MouthyTheme.orange : MouthyTheme.cream.opacity(hovering ? 0.14 : 0.09))
            Circle().strokeBorder(MouthyTheme.cream.opacity(listening ? 0 : 0.16), lineWidth: 1)
            Image(systemName: listening ? "stop.fill" : "mic.fill")
                .font(.system(size: listening ? 14 : 17, weight: .semibold))
                .foregroundStyle(listening ? MouthyTheme.night : MouthyTheme.cream)
        }
        .frame(width: 44, height: 44)
        .opacity(finishing ? 0.5 : 1)
        .animation(MouthyMotion.hover, value: hovering)
        .animation(MouthyMotion.hover, value: listening)
        .onHover { hovering = $0 }
    }
}

/// A row that lights up softly under the pointer.
struct HoverRow: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MouthyTheme.cream.opacity(hovering ? 0.06 : 0)))
            .animation(MouthyMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverRow() -> some View { modifier(HoverRow()) }
}

struct VoiceStat: View {
    let value: Int
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted()).font(.system(size: 18, weight: .regular, design: .rounded)).monospacedDigit()
                .foregroundStyle(MouthyTheme.cream)
                .contentTransition(.numericText())
            Text(label).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundStyle(MouthyTheme.cream2)
        }
        .accessibilityElement(children: .combine)
    }

    /// The label under a count, inflected for it: "1 dictation", "2 dictations", through the system's grammar.
    static func noun(_ singular: String, _ count: Int) -> String {
        let inflected = String(AttributedString(localized: "^[\(count) \(singular)](inflect: true)").characters)
        return inflected.split(separator: " ", maxSplits: 1).last.map(String.init) ?? singular
    }
}

/// Teach Mouthy a word it keeps getting wrong: what it heard (optional) and what you meant.
struct TeachRow: View {
    @ObservedObject var model: AppModel
    @State private var heard = ""
    @State private var meant = ""
    @State private var learned: String?
    var body: some View {
        HStack(spacing: 6) {
            NotchField(prompt: "It heard…", text: $heard)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(MouthyTheme.cream2)
            NotchField(prompt: "You meant…", text: $meant, onSubmit: teach)
            PillButton(title: learned == nil ? "Teach" : "Learned", symbol: learned == nil ? "graduationcap" : "checkmark",
                       prominent: !meant.isEmpty, action: teach)
                .fixedSize()
        }
    }
    private func teach() {
        guard !meant.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.teach(heard: heard, meant: meant)
        learned = meant; heard = ""; meant = ""
        Task { try? await Task.sleep(for: .seconds(2)); learned = nil }
    }
}
