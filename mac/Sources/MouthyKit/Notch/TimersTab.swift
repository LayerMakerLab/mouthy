import AppKit
import MouthyNotch
import SwiftUI

/// Pomodoro, a countdown and a stopwatch. Nothing ticks unless something is running and visible.
@MainActor final class TimersTab: ObservableObject, NotchTab {
    static let shared = TimersTab()
    enum Kind: String, Codable, CaseIterable { case focus, rest, countdown }
    struct Running: Equatable {
        var kind: Kind; var ends: Date; var length: TimeInterval
        /// Clock ticks fall on whole seconds from here, so the readout changes exactly once a second.
        var started: Date { ends.addingTimeInterval(-length) }
    }

    let id = "mouthy.timers"
    let title = "Timers"
    let symbolName = "timer"
    @Published private(set) var running: Running?
    @Published private(set) var stopwatchStart: Date?
    @Published private(set) var stopwatchBanked: TimeInterval = 0
    @Published var countdownMinutes = 10
    /// The timer Start will run; its length shows in the ring before it starts.
    @Published var selected: Kind = .focus
    @Published private(set) var finished: Kind?
    @Published private(set) var streak: Int
    var focusMinutes = 25, restMinutes = 5
    private var alarm: Task<Void, Never>?

    private init() {
        let saved = NotchFile.load(Streak.self, "pomodoro.json")
        streak = saved?.day == Streak.todayKey ? saved?.today ?? 0 : 0
    }

    var prefersAttention: Bool { finished != nil }
    var badge: NotchBadge? { running == nil ? nil : NotchBadge(count: 0, tone: .active) }
    var ambientColor: Color? { running?.kind == .rest ? MouthyTheme.cream2 : running != nil ? MouthyTheme.glow : nil }

    func minutes(for kind: Kind) -> Int {
        switch kind { case .focus: focusMinutes; case .rest: restMinutes; case .countdown: countdownMinutes }
    }

    func start(_ kind: Kind) { begin(kind, length: TimeInterval(minutes(for: kind) * 60)) }

    /// A spoken timer: a countdown of any length, with the same ring and done peek.
    func start(seconds: Int) { begin(.countdown, length: TimeInterval(max(1, seconds))) }

    private func begin(_ kind: Kind, length: TimeInterval) {
        selected = kind
        running = Running(kind: kind, ends: Date().addingTimeInterval(length), length: length)
        finished = nil
        schedule()
    }

    func stop() { alarm?.cancel(); running = nil; changed() }

    private func schedule() {
        alarm?.cancel()
        guard let running else { return }
        changed()
        alarm = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, running.ends.timeIntervalSinceNow))) } catch { return }
            self?.complete(running.kind)
        }
    }

    private func complete(_ kind: Kind) {
        running = nil
        finished = kind
        if kind == .focus {
            streak += 1
            NotchFile.save(Streak(day: Streak.todayKey, today: streak), "pomodoro.json")
        }
        NSSound(named: "Glass")?.play()
        changed()
        let ears = Self.doneEars
        NotchHub.shared.peek(AnyView(TimerDonePeek(kind: kind, streak: streak)), seconds: 4,
                             leading: ears.leading, trailing: ears.trailing, title: "\(TimersTab.name(kind)) done")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.finished = nil; self?.changed()
        }
    }

    func toggleStopwatch() {
        if let start = stopwatchStart { stopwatchBanked += Date().timeIntervalSince(start); stopwatchStart = nil }
        else { stopwatchStart = Date() }
        changed()
    }
    func resetStopwatch() { stopwatchStart = nil; stopwatchBanked = 0; changed() }

    private func changed() { NotchHub.shared.tabDidChange(id: id) }

    func makeBody() -> AnyView { AnyView(TimersView(model: self)) }
    var compactPriority: Int { Self.runningPriority }
    static let runningPriority = 20
    func compactLeading() -> AnyView? {
        guard let running else { return nil }
        // The time left as a ring that empties, in Core Animation: nothing redraws each second.
        return AnyView(TimerRingLayers(ends: running.ends, length: running.length, lineWidth: 2.5,
                                       tint: running.kind == .rest ? MouthyTheme.cream2 : MouthyTheme.orange)
            .frame(width: 16, height: 16))
    }
    var compactCaption: String? { running.map { TimersTab.name($0.kind) } }
    func compactBody() -> AnyView? {
        guard let running else { return nil }
        return AnyView(TimelineView(.periodic(from: running.started, by: 1)) { _ in
            Text(formatClock(running.ends.timeIntervalSinceNow)).monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        })
    }

    /// The band beside the camera when a session ends: the timer glyph, then "Done" (the card says which).
    static var doneEars: (leading: AnyView, trailing: AnyView) {
        // A text glyph: the timer symbol drawn as an Image ignores the foreground style and draws white.
        (AnyView(Text(Image(systemName: "timer")).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(MouthyTheme.glow)),
         AnyView(Text("Done")))
    }

    static func name(_ kind: Kind) -> String {
        switch kind { case .focus: "Focus"; case .rest: "Break"; case .countdown: "Timer" }
    }

    struct Streak: Codable {
        var day: String; var today: Int
        static var todayKey: String { Date().formatted(.iso8601.year().month().day()) }
    }
}

struct TimersView: View {
    @ObservedObject var model: TimersTab
    var body: some View {
        // While one side runs, the idle side steps back so the live timer is the one thing that reads.
        let focusLive = model.running != nil
        let stopwatchLive = model.stopwatchStart != nil
        let focusQuiet = stopwatchLive && !focusLive
        let stopwatchQuiet = focusLive && !stopwatchLive
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                TabHeader(title: "Focus", detail: model.streak > 0 ? "\(model.streak) today" : nil)
                HStack(alignment: .center, spacing: 18) {
                    TimerRing(model: model, quiet: focusQuiet)
                        .frame(width: 84, height: 84)
                    VStack(alignment: .leading, spacing: 8) {
                        if let running = model.running {
                            Text("Ends " + running.ends.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 13.5)).foregroundStyle(MouthyTheme.cream2)
                            PillButton(title: "Stop", symbol: "stop.fill") { model.stop() }
                        } else {
                            HStack(spacing: 6) {
                                ForEach(TimersTab.Kind.allCases, id: \.self) { kind in
                                    KindChip(title: kind == .countdown ? "Timer" : "\(TimersTab.name(kind)) \(model.minutes(for: kind))",
                                             selected: model.selected == kind) {
                                        withAnimation(MouthyMotion.select) { model.selected = kind }
                                    }
                                }
                            }
                            if model.selected == .countdown {
                                Stepper(value: $model.countdownMinutes, in: 1...180) {
                                    Text("\(model.countdownMinutes) min").font(.system(size: 13.5, design: .rounded)).monospacedDigit()
                                        .foregroundStyle(MouthyTheme.cream)
                                        .contentTransition(.numericText())
                                }
                                .fixedSize()
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                            PillButton(title: "Start \(TimersTab.name(model.selected).lowercased())", symbol: "play.fill", prominent: !focusQuiet) {
                                model.start(model.selected)
                            }
                        }
                    }
                    .animation(MouthyMotion.select, value: model.selected)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // As tall as the content, not the panel.
            Rectangle().fill(MouthyTheme.cream.opacity(0.08)).frame(width: 1).padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 10) {
                TabHeader(title: "Stopwatch")
                // Whole seconds, running or paused: one tick a second, and the readout keeps one format.
                TimelineView(.periodic(from: (model.stopwatchStart ?? .now).addingTimeInterval(-model.stopwatchBanked.truncatingRemainder(dividingBy: 1)),
                                       by: model.stopwatchStart == nil ? 3600 : 1)) { _ in
                    let elapsed = model.stopwatchBanked + (model.stopwatchStart.map { Date().timeIntervalSince($0) } ?? 0)
                    Text(formatClock(floor(elapsed)))
                        .font(MouthyType.notchStopwatch)
                        .foregroundStyle(stopwatchLive ? AnyShapeStyle(barGradient)
                                         : AnyShapeStyle(stopwatchQuiet ? MouthyTheme.cream2.opacity(0.5) : MouthyTheme.cream))
                        .padding(.vertical, 6)
                }
                HStack {
                    PillButton(title: model.stopwatchStart == nil ? "Start" : "Pause",
                               symbol: model.stopwatchStart == nil ? "play.fill" : "pause.fill",
                               prominent: !stopwatchLive && !stopwatchQuiet && model.stopwatchBanked == 0) { model.toggleStopwatch() }
                    PillButton(title: "Reset") { model.resetStopwatch() }
                        .disabled(model.stopwatchStart == nil && model.stopwatchBanked == 0)
                }
            }
            .frame(width: 150, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(MouthyMotion.select, value: focusQuiet)
        .animation(MouthyMotion.select, value: stopwatchQuiet)
    }
}

/// The focus ring: time left while running, otherwise the selected length.
struct TimerRing: View {
    @ObservedObject var model: TimersTab
    /// The stopwatch is the live one: the idle length steps back.
    var quiet = false
    var body: some View {
        ZStack {
            if let running = model.running {
                // The ring fills on Core Animation; only the clock text ticks, once a second.
                TimerRingLayers(ends: running.ends, length: running.length, tint: running.kind == .rest ? MouthyTheme.cream2 : MouthyTheme.orange)
                TimelineView(.periodic(from: running.started, by: 1)) { _ in
                    label(formatClock(running.ends.timeIntervalSinceNow),
                          caption: running.kind == .focus ? "Focusing" : running.kind == .rest ? "On a break" : "Countdown")
                }
            } else {
                GlowRing(progress: model.finished == nil ? 0 : 1)
                label("\(model.minutes(for: model.selected)):00",
                      caption: model.finished == .focus ? "Nice work" : model.finished == nil ? TimersTab.name(model.selected) : "Done",
                      highlight: model.finished != nil, quiet: quiet)
            }
        }
        .padding(2)
        .accessibilityElement(children: .combine)
    }

    private func label(_ time: String, caption: String, highlight: Bool = false, quiet: Bool = false) -> some View {
        VStack(spacing: 1) {
            Text(time).font(MouthyType.notchTimer).foregroundStyle(quiet ? MouthyTheme.cream2.opacity(0.5) : MouthyTheme.cream)
                .contentTransition(.numericText(countsDown: true))
            Text(caption).font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(highlight ? MouthyTheme.glow : MouthyTheme.cream2)
        }
    }
}

/// A small choice capsule: selected is raised cream ink, the rest quiet.
struct KindChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .foregroundStyle(selected ? MouthyTheme.cream : hovering ? MouthyTheme.cream : MouthyTheme.cream2)
                .padding(.horizontal, 9).frame(minHeight: 24)
                .background(Capsule(style: .circular).fill(MouthyTheme.cream.opacity(selected ? 0.16 : hovering ? 0.05 : 0)))
                .overlay(Capsule(style: .circular).strokeBorder(selected ? MouthyTheme.glow.opacity(0.35) : MouthyTheme.cream.opacity(0.08), lineWidth: 0.8))
                .contentShape(Capsule(style: .circular))
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The card when a session ends: the giraffe cheers for focus, a bell rings for the rest.
struct TimerDonePeek: View {
    let kind: TimersTab.Kind
    let streak: Int
    @State private var rang = false
    var body: some View {
        NotchPeekRow(title: kind == .focus ? "Focus complete" : kind == .rest ? "Break's over" : "Time's up",
                     detail: kind == .focus && streak > 0 ? "\(streak) today" : nil) {
            if kind == .focus {
                MascotGlyph(pose: .cheer, size: 24)
            } else {
                Image(systemName: "bell.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
                    .symbolEffect(.bounce, value: rang)
            }
        }
        .onAppear { rang = true }
    }
}
