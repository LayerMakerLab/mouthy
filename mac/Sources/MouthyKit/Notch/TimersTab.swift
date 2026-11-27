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
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                TabHeader(title: "Focus", detail: model.streak > 0 ? "\(model.streak) today" : nil)
                HStack(alignment: .center, spacing: 12) {
                    TimerRing(model: model, quiet: focusQuiet)
                        .frame(width: 68, height: 68)
                    VStack(alignment: .leading, spacing: 8) {
                        if let running = model.running {
                            Text("Ends " + running.ends.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12.5)).foregroundStyle(MouthyTheme.cream2)
                            PillButton(title: "Stop", symbol: "stop.fill") { model.stop() }
                        } else {
                            // What to time, as one segmented control; then Start, with the minutes beside it for a
                            // plain timer.
                            HStack(spacing: 2) {
                                ForEach(TimersTab.Kind.allCases, id: \.self) { kind in
                                    // (The ring beside it shows the length of the one that is chosen.)
                                    KindChip(title: kind == .countdown ? "Timer" : TimersTab.name(kind), selected: model.selected == kind) {
                                        withAnimation(MouthyMotion.select) { model.selected = kind }
                                    }
                                }
                            }
                            .padding(2)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MouthyTheme.cream.opacity(0.06)))
                            .fixedSize()
                            HStack(spacing: 8) {
                                PillButton(title: "Start", symbol: "play.fill", prominent: !focusQuiet) { model.start(model.selected) }
                                    .accessibilityLabel("Start \(TimersTab.name(model.selected).lowercased())")
                                if model.selected == .countdown {
                                    MinuteStepper(minutes: $model.countdownMinutes)
                                        .transition(.opacity)
                                }
                            }
                        }
                    }
                    .animation(MouthyMotion.select, value: model.selected)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .notchTile()
            VStack(alignment: .leading, spacing: 0) {
                TabHeader(title: "Stopwatch")
                // Whole seconds, running or paused: one tick a second, and the readout keeps one format.
                TimelineView(.periodic(from: (model.stopwatchStart ?? .now).addingTimeInterval(-model.stopwatchBanked.truncatingRemainder(dividingBy: 1)),
                                       by: model.stopwatchStart == nil ? 3600 : 1)) { _ in
                    let elapsed = model.stopwatchBanked + (model.stopwatchStart.map { Date().timeIntervalSince($0) } ?? 0)
                    Text(formatClock(floor(elapsed)))
                        .font(.system(size: 26, weight: .regular, design: .rounded).monospacedDigit())
                        .foregroundStyle(stopwatchLive ? AnyShapeStyle(MouthyTheme.barFill)
                                         : AnyShapeStyle(stopwatchQuiet ? MouthyTheme.cream2.opacity(0.5) : MouthyTheme.cream))
                        .frame(maxHeight: .infinity)
                }
                HStack(spacing: 6) {
                    PillButton(title: model.stopwatchStart == nil ? "Start" : "Pause",
                               symbol: model.stopwatchStart == nil ? "play.fill" : "pause.fill",
                               prominent: false) { model.toggleStopwatch() }
                    PillButton(title: "Reset") { model.resetStopwatch() }
                        .disabled(model.stopwatchStart == nil && model.stopwatchBanked == 0)
                }
            }
            .frame(width: 150, alignment: .leading)
            .notchTile()
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
                TimerRingLayers(ends: running.ends, length: running.length, lineWidth: 4.5, tint: running.kind == .rest ? MouthyTheme.cream2 : MouthyTheme.orange)
                TimelineView(.periodic(from: running.started, by: 1)) { _ in
                    label(formatClock(running.ends.timeIntervalSinceNow),
                          caption: running.kind == .focus ? "Focusing" : running.kind == .rest ? "On a break" : "Countdown")
                }
            } else {
                GlowRing(progress: model.finished == nil ? 0 : 1, lineWidth: 4.5)
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
            // (A spoken timer can run for hours: "12:34:55" is scaled to stay inside the ring.)
            Text(time).font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: 46)
                .foregroundStyle(quiet ? MouthyTheme.cream2.opacity(0.5) : MouthyTheme.cream)
                .contentTransition(.numericText(countsDown: true))
            Text(caption).font(.system(size: 8.5, weight: .medium)).lineLimit(1).fixedSize()
                .foregroundStyle(highlight ? MouthyTheme.glow : MouthyTheme.cream2)
        }
    }
}

/// One choice in a segmented control: the selected one is a raised fill, the rest are plain labels.
struct KindChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .foregroundStyle(selected || hovering ? MouthyTheme.cream : MouthyTheme.cream2)
                .padding(.horizontal, 8).frame(minHeight: 22)
                .background(shape.fill(MouthyTheme.cream.opacity(selected ? 0.16 : hovering ? 0.06 : 0)))
                .contentShape(shape)
        }
        .buttonStyle(NotchPressStyle())
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The minutes of a plain timer: minus, the number, plus, as one control (the system stepper is another app's look).
struct MinuteStepper: View {
    @Binding var minutes: Int
    var range = 1...180
    var body: some View {
        HStack(spacing: 0) {
            step("minus", by: -1)
            Text("\(minutes) min").font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                .foregroundStyle(MouthyTheme.cream).contentTransition(.numericText())
                .lineLimit(1).fixedSize()
                .frame(minWidth: 46)
            step("plus", by: 1)
        }
        .frame(height: 26)
        .fixedSize()
        .background(PillButton.shape.fill(MouthyTheme.cream.opacity(0.07)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minutes").accessibilityValue("\(minutes)")
        .accessibilityAdjustableAction { direction in
            minutes = min(range.upperBound, max(range.lowerBound, minutes + (direction == .increment ? 1 : -1)))
        }
    }
    private func step(_ symbol: String, by change: Int) -> some View {
        Button {
            withAnimation(MouthyMotion.select) { minutes = min(range.upperBound, max(range.lowerBound, minutes + change)) }
        } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(MouthyTheme.cream2)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(NotchPressStyle())
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
