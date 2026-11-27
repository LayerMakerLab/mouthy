import AppKit
import ApplicationServices
import Carbon
import MouthyCore

/// "Type as I speak": types the live words into the focused field while the person talks, corrects them as
/// recognition settles and brings the field to the finished text at the stop. `LiveTyping` (MouthyCore) decides what
/// to type; this posts the key presses and guards the field.
///
/// Where it types: only a focused AXTextField or AXTextArea with no text selected, never a password field or under
/// secure input, never through an input method (Japanese, Chinese, Korean: key presses would go through it), and
/// never while ⌘, ⌃ or ⌥ is held (the key presses would become commands). Focus is checked right before every run
/// of key presses, with nothing awaited between the check and the presses; a long edit goes out in runs that each
/// end on a whole word.
///
/// What it may take back: after its first words it reads the field (`look`). A field that shows them before the
/// cursor is read again before every backspace, and every typed character must be there, in order, the last one at
/// the cursor (`holds`). A field whose text holds the words but not at the cursor it reports (some terminals)
/// cannot be read and is trusted while it keeps the focus and no key or click comes. A field that shows other text
/// where the words should be has changed them (autocorrect): they are left alone. A field whose text never changed
/// is not taking the key presses: nothing counts as typed and the stop pastes everything.
///
/// When the person types, clicks or changes fields, or a check fails, the words typed so far stay as they are and
/// live typing stops: the stop delivers the words after them. Only if the cursor is found exactly where the words
/// ended, in the same field, with exactly those words between where typing began and the cursor, are they taken up
/// again (`reclaim`). A line break is never typed (it would press Return): text from the first one on is left to
/// the paste at the end.
@MainActor
final class LiveTyper {
    /// Where key presses go: the keyboard stream. Tests send them to a background target instead.
    static var post: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    /// A guess stands when no newer one came for this long (the person paused). Long enough that a guess is not
    /// taken for the last one while a pass is still running: at 0.3 s the whole guess was typed in those gaps, made-up
    /// endings included (four of five typed words that the finished text did not have came from that, in ten
    /// replays), and a typed word now stays until the stop.
    static var settleAfter: Duration = .milliseconds(800)
    /// The same for the streaming recognizer's words, which it never takes back by itself.
    static var settleAfterFirm: Duration = .milliseconds(300)
    /// After the person types or clicks, this long passes before the cursor is looked for again.
    static var quiet: Duration = .milliseconds(700)
    /// Whether ⌘, ⌃ or ⌥ is physically down: a key press posted now could be taken as a command.
    static var modifiersHeld: () -> Bool = {
        !CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    }
    /// Whether the keyboard types letters directly (a layout), not through an input method.
    static var plainKeyboard: () -> Bool = {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { return true }
        return CFEqual(Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue(), kTISTypeKeyboardLayout)
    }
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea"]
    /// Key presses after which the next whole word ends a run and focus is checked again.
    static let burst = 24
    /// Typed characters checked before a backspace (the newest; a dictation is rarely longer).
    static let checked = 4_000

    enum Outcome: Equatable {
        /// The field holds the text up to its first line break. `rest` is still to paste (empty for almost every
        /// dictation); `verified` when the field was read back and ends with the typed text.
        case typed(rest: String, verified: Bool)
        /// Nothing more could be typed: this is what no field has yet (all of the text when nothing was typed).
        case untyped(String)
    }

    private var typing: LiveTyping
    private let shape: (String) -> String
    private let smartFormatting: Bool
    private var pid: pid_t = 0
    private var field: AXUIElement?
    private var attached = false
    /// What reading the field back after the first words showed.
    private enum Sight { case unknown, readable, blind }
    private var sight = Sight.unknown
    /// A hash of the field's whole text when typing began, to tell whether key presses change it at all.
    private var valueAtAttach: Int?
    /// The cursor position (UTF-16) where typing began, when the app reports it.
    private var start: Int?
    /// Where words were left behind: they are taken up again only there.
    private var leftSpot: (pid: pid_t, field: AXUIElement, start: Int?, readable: Bool)?
    private var reclaimAfter: ContinuousClock.Instant?
    /// What is really in the field while a run of key presses is going out.
    private var sending: String?
    private var heardAt: ContinuousClock.Instant?
    /// An app that cannot be typed into right now: not asked again until the person types or clicks.
    private var refused: pid_t?
    /// Goes up whenever the typed words are left behind, so work that waited on the field can tell.
    private var runs = 0
    private var latest: String?
    private var latestIsFirm = false
    private var latestPause: LiveTyping.Pause?
    /// The newest pause's text, until it has gone into the field.
    private var pending: (raw: String, pause: LiveTyping.Pause, id: Int)?
    private var pendingCount = 0, retries = 0
    private var latestPending: Int?
    static let retryAfter = Duration.milliseconds(400)
    static let retryLimit = 5
    private var settleDue = false
    private var pump: Task<Void, Never>?
    private var settle: Task<Void, Never>?
    private var paused = false
    private var ended = false
    /// Whether any key press went out during this dictation or part.
    private(set) var typedAnything = false
    /// Key presses of this dictation, for the log line at the stop: characters typed and backspaces. Never any text.
    private var pressed = (typed: 0, back: 0)
    /// The last finished text in numbers: characters typed, and taken back while speaking and at the stop
    /// (`DictationScore`).
    private(set) var counts: (typed: Int, back: Int, backAtStop: Int)?
    /// The app typed into last, for the status line.
    private(set) var appName = ""
    /// Whether the field typed into still has the focus (checked before a Return follows the words). An app too
    /// busy to answer is asked again for up to half a second.
    func stillThere() async -> Bool { await answeredFocus() == .here }
    /// Whether words of this dictation were left behind where the person moved on from them.
    var leftWords: Bool { !typing.left.isEmpty }
    /// Called when the words start or stop going into a field: a field took them, none can, they were left behind,
    /// or the field is not getting all of them (a held modifier, an app too busy to answer, text after a line
    /// break). While they do go in, nothing else needs to show them.
    var onTyping: ((Bool) -> Void)?

    /// `shape` applies the dictation's text rules to a guess, so what is typed live is what the finished text will
    /// say; `names` are the person's custom words.
    /// `settlesAtPauses`: the recognizer says when it heard a pause, so a phrase is typed then and no guess before.
    init(shape: @escaping (String) -> String, smartFormatting: Bool, names: [String], settlesAtPauses: Bool = false) {
        self.shape = shape
        self.smartFormatting = smartFormatting
        typing = LiveTyping(names: names)
        typing.settlesAtPauses = settlesAtPauses
    }

    /// A new guess at everything said so far.
    /// `firm`: the guess's newest words are the streaming recognizer's, which never change by themselves, so all of
    /// it is typed at once.
    /// `pause`: a pass's text of everything said up to a pause.
    func hear(_ raw: String, firm: Bool = false, pause: LiveTyping.Pause? = nil) {
        guard !paused, !ended, !raw.isEmpty else { return }
        // The recognizer says when a pause was heard: no clock stands in for it. (A second without a newer guess
        // also comes while a pass runs and the person talks on, and the guess then typed ended in words the
        // recognizer had made up.) A guess types nothing then; the phrase of the last pause waits until it has
        // gone in (a busy app, a held key, a click just before: review round 1), and every guess and a short timer
        // try it again.
        if typing.settlesAtPauses, !firm {
            if let pause { pendingCount += 1; pending = (raw, pause, pendingCount); retries = 0 }
            guard let pending else { return }
            latest = pending.raw; latestIsFirm = false; latestPause = pending.pause; latestPending = pending.id
            settle?.cancel()
            if retries < Self.retryLimit {
                settle = Task { [weak self] in
                    try? await Task.sleep(for: Self.retryAfter)
                    guard !Task.isCancelled, let self, let pending = self.pending, pending.id == self.pendingCount else { return }
                    self.retries += 1
                    self.hear(pending.raw)
                }
            }
            run()
            return
        }
        latest = raw; latestIsFirm = firm; latestPause = pause; latestPending = nil
        // A pause is a gap of twice the time between guesses (a slow Mac guesses less often), at least `settleAfter`.
        let now = ContinuousClock.now
        let gap = heardAt.map { min($0.duration(to: now), .seconds(1)) } ?? .zero
        heardAt = now
        let wait = max(firm ? Self.settleAfterFirm : Self.settleAfter, gap * 2)
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            self.settleDue = true
            self.run()
        }
        run()
    }

    /// The person pressed a key or clicked: the words typed so far are theirs now.
    func touched() {
        guard !ended else { return }
        refused = nil
        if attached { leave("the person typed or clicked") }
        reclaimAfter = .now + Self.quiet
    }

    /// Stops typing guesses: an Enter split is taking the words so far (guesses that come before `restart` belong
    /// to the next part), or the dictation was cancelled.
    func pause() {
        paused = true
        latest = nil; settleDue = false; pending = nil
        settle?.cancel()
        // Until typing goes on, the words said meanwhile show where they always did.
        blocked = Self.patience
        report()
    }

    /// The part was delivered: the next one starts at the cursor.
    func restart() {
        let settlesAtPauses = typing.settlesAtPauses
        typing = LiveTyping(names: typing.names)
        typing.settlesAtPauses = settlesAtPauses
        attached = false; field = nil; leftSpot = nil; reclaimAfter = nil; refused = nil; runs += 1
        paused = false; ended = false; typedAnything = false; heardAt = nil; pending = nil
        blocked = 0; pressed = (0, 0)
    }

    /// Brings the field to the finished `text`.
    func finish(_ text: String) async -> Outcome {
        await quiesce()
        defer { ended = true }
        let before = pressed
        let outcome = await complete(text)
        counts = (pressed.typed, before.back, pressed.back - before.back)
        // How restless the field was, in numbers: what was taken back while the person spoke, and for the finished text.
        let how = switch outcome {
        case .typed(_, let verified): verified ? "finished in the field and read back" : "finished in the field, not read back"
        case .untyped(let rest): rest.isEmpty ? "nothing left to paste" : "the rest (\(rest.count) characters) goes to the paste"
        }
        Diagnostics.dictation.notice("live typing: typed \(self.pressed.typed, privacy: .public) characters, took back \(before.back, privacy: .public) while speaking and \(self.pressed.back - before.back, privacy: .public) at the stop, \(how, privacy: .public)")
        return outcome
    }

    private func complete(_ text: String) async -> Outcome {
        // A stale record of an earlier insertion must not be learned from as if it were this one.
        TextDelivery.lastInsertion = nil
        let released = await modifiersReleased()
        if !attached, released { reclaim() }
        if attached, released, await answeredFocus() == .here {
            var next = typing
            let finished = next.finish(text)
            let run = runs
            if await owns(finished.edits), run == runs, await send(finished.edits, patient: true) {
                typing = next
                // The words are in the field now. Ones that first went out just now (a short dictation) are read
                // back like any first words; only a field that took none of them hands the text to the paste.
                if sight == .unknown, !typing.typed.isEmpty, await look() == .dead {
                    return .untyped(text)
                }
                return .typed(rest: finished.rest, verified: finished.rest.isEmpty && attached ? await verify() : false)
            }
        }
        if attached { leave("the field could not be finished in place") }
        return .untyped(typing.remainder(of: text, seam: cursorStillAfterLeftWords()))
    }

    /// Takes the typed words back (a cancelled dictation, or a result that goes somewhere else). Returns whether
    /// words are still in a field: ones the person moved on from, or a field that could not be read.
    @discardableResult
    func takeBack() async -> Bool {
        await quiesce()
        ended = true
        let released = await modifiersReleased()
        if !attached, released { reclaim() }
        if attached, !typing.typed.isEmpty, released, await answeredFocus() == .here {
            var next = typing
            let edits = next.erase()
            let run = runs
            if await owns(edits), run == runs, await send(edits, patient: true) { typing = next }
        }
        return !typing.left.isEmpty || !typing.typed.isEmpty
    }

    /// Stops typing and leaves the words where they are (a failed dictation: they are still what was said).
    func abandon() {
        ended = true
        latest = nil; settleDue = false; pending = nil
        settle?.cancel()
    }

    private func quiesce() async {
        settle?.cancel()
        latest = nil; settleDue = false; pending = nil
        await pump?.value
    }

    private func run() {
        guard pump == nil else { return }
        pump = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !ended, !paused {
            if let raw = latest {
                latest = nil
                let id = latestPending; latestPending = nil
                await step(shape(raw), firm: latestIsFirm, pause: latestPause, pending: id)
            } else if settleDue {
                settleDue = false
                await step(nil)
            } else { break }
        }
        pump = nil
    }

    private var reported: Bool?
    /// Guesses in a row that a focused field did not get in full: a modifier was down, the app did not answer, or
    /// the text goes on after a line break.
    private var blocked = 0
    /// How many such guesses pass before the words are shown elsewhere (a busy app for one guess is not worth a
    /// card popping up and away).
    static let patience = 3
    /// Tells `onTyping` whether the words are going into a field, when that changed.
    private func report() {
        let typingNow = attached && !paused && blocked < Self.patience
        guard reported != typingNow else { return }
        reported = typingNow
        onTyping?(typingNow)
    }

    /// One guess (`nil`: the last one stands).
    private func step(_ text: String?, firm: Bool = false, pause: LiveTyping.Pause? = nil, pending id: Int? = nil) async {
        // Whatever this guess did (a field took the words, none can, they were left), say so once it is known.
        var wentIn = false
        defer {
            blocked = wentIn && !typing.heardMore ? 0 : blocked + 1
            report()
        }
        func remember() { if let text { _ = typing.hear(text, typing: false, firm: firm) } }
        if attached {
            switch focus() {
            case .here: break
            case .gone: leave("focus moved")
            case .unknown: return remember()   // the app is busy: nothing is typed, nothing is given up
            }
        }
        if !attached {
            if typing.left.isEmpty { attach() } else if let reclaimAfter, reclaimAfter <= .now { reclaim() }
        }
        guard attached else { return remember() }
        var next = typing
        let edits = text.map { next.hear($0, firm: firm, pause: pause) } ?? next.settle()
        let run = runs
        guard await owns(edits) else {
            if run == runs { leave("the field no longer ends with the typed words") }
            return remember()
        }
        guard run == runs, attached, !ended, !paused, await send(edits) else {
            // Nothing went out (a modifier is down, the app is busy), or the words were left meanwhile.
            if run == runs { remember() }
            return
        }
        typing = next
        wentIn = true
        // Gone in: neither the timer nor a guess that came meanwhile may hand it over again (a phrase heard while the
        // person talked on, handed over twice, confirmed its own held-back words: review round 2).
        if let id, pending?.id == id {
            pending = nil; settle?.cancel()
            if latestPending == id { latest = nil; latestPending = nil }
        }
        if sight == .unknown, !typing.typed.isEmpty { _ = await look() }
    }

    private func attach() {
        guard !IsSecureEventInputEnabled(), TextDelivery.accessibilityAllowed, let app = TextDelivery.frontmost(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, refused != app.processIdentifier else { return }
        if let reclaimAfter, reclaimAfter > .now { return }
        func refuse(_ why: String) {
            refused = app.processIdentifier
            Diagnostics.dictation.notice("live typing: \(why, privacy: .public), the words wait for the stop")
        }
        guard Self.plainKeyboard() else { return refuse("the keyboard uses an input method") }
        guard let element = TextDelivery.focusedElement(pid: app.processIdentifier),
              let role = TextDelivery.role(of: element), Self.textRoles.contains(role),
              TextDelivery.subrole(of: element) != kAXSecureTextFieldSubrole else { return refuse("no text field is focused") }
        AXUIElementSetMessagingTimeout(element, 0.15)
        let range = TextDelivery.selectionRange(element)
        // Typing would replace a selection at the first word, and Escape could not bring it back.
        if let range, range.length > 0 { return refuse("text is selected") }
        pid = app.processIdentifier
        field = element
        appName = app.localizedName ?? "App"
        let value = TextDelivery.value(of: element)
        valueAtAttach = value?.hashValue
        start = range.flatMap { $0.location >= 0 ? $0.location : nil }
        let around = smartFormatting ? TextDelivery.surroundings(of: value, range: range) : nil
        typing.attach(before: around?.before, after: around?.after)
        attached = true; sight = .unknown; leftSpot = nil
        Diagnostics.dictation.notice("live typing: typing into a \(role, privacy: .public)\(around == nil ? " that reports no text" : "", privacy: .public)")
    }

    private func leave(_ reason: String) {
        typing.leave(holding: sending)
        if let field { leftSpot = (pid, field, start, sight == .readable) }
        attached = false; field = nil
        runs += 1
        report()
        reclaimAfter = .now + Self.quiet
        Diagnostics.dictation.notice("live typing: left the typed words, \(reason, privacy: .public)")
    }

    /// Takes the left words up again when the cursor is exactly where they ended: the same field, readable, nothing
    /// selected, and between where typing began and the cursor those words, character for character (only case and
    /// the kind of quote may differ). Anything less leaves them alone: the person's own "thanks" elsewhere in the
    /// field ends like Mouthy's "Thanks", and a comma they added inside the words would be taken back with them.
    private func reclaim() {
        reclaimAfter = .now + .seconds(1)
        guard let spot = leftSpot, spot.readable, let start = spot.start, let text = typing.abandonedText,
              !IsSecureEventInputEnabled(), Self.plainKeyboard(), TextDelivery.frontmost()?.processIdentifier == spot.pid,
              case .success(let now?) = Self.focused(spot.pid), CFEqual(now, spot.field),
              let range = TextDelivery.selectionRange(spot.field), range.length == 0,
              range.location - start == text.utf16.count,
              let between = Self.text(of: spot.field, from: start, to: range.location), Self.same(between, text) else { return }
        pid = spot.pid; field = spot.field
        attached = true; sight = .readable; leftSpot = nil; reclaimAfter = nil
        typing.reclaim()
        Diagnostics.dictation.notice("live typing: the cursor is still after the typed words, taking them up again")
    }

    /// Whether the cursor is most likely still right after the left words although the field cannot say so: the
    /// same field has the focus and it never showed its text at the cursor. The paste then needs the seam.
    private func cursorStillAfterLeftWords() -> Bool {
        guard let spot = leftSpot, !spot.readable, TextDelivery.frontmost()?.processIdentifier == spot.pid,
              case .success(let now?) = Self.focused(spot.pid) else { return false }
        return CFEqual(now, spot.field)
    }

    private enum Focus { case here, gone, unknown }

    /// Whether the same app and field have the focus, with no password field or secure input. `unknown`: the app
    /// did not answer in time.
    private func focus() -> Focus {
        guard attached, let field, TextDelivery.frontmost()?.processIdentifier == pid, !IsSecureEventInputEnabled() else { return .gone }
        switch Self.focused(pid) {
        case .failure: return .unknown
        case .success(let now): return now.map { CFEqual($0, field) } == true && TextDelivery.subrole(of: field) != kAXSecureTextFieldSubrole ? .here : .gone
        }
    }

    /// `focus()`, asking an app that did not answer again for up to half a second: at the stop the words must not
    /// be given up because the app was busy for a moment.
    private func answeredFocus() async -> Focus {
        var state = focus()
        for _ in 0..<10 where state == .unknown {
            try? await Task.sleep(for: .milliseconds(50))
            state = focus()
        }
        return state
    }

    private struct NoAnswer: Error {}

    /// The app's focused element in one short Accessibility read; a failure when it did not answer in 0.15 s.
    private static func focused(_ pid: pid_t) -> Result<AXUIElement?, NoAnswer> {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .success(nil) }
            return .success((value as! AXUIElement))
        case .cannotComplete: return .failure(NoAnswer())
        default: return .success(nil)
        }
    }

    private func modifiersReleased() async -> Bool {
        for _ in 0..<40 where Self.modifiersHeld() { try? await Task.sleep(for: .milliseconds(25)) }
        return !Self.modifiersHeld()
    }

    private enum Looked { case readable, blind, changed, dead, interrupted }

    /// After the first words: does the field show them before the cursor?
    @discardableResult
    private func look() async -> Looked {
        guard let field else { return .interrupted }
        let run = runs
        for _ in 0..<40 {
            guard let before = textBeforeCursor(field) else { sight = .blind; return .blind }
            if Self.holds(before, typing.typed) { sight = .readable; return .readable }
            try? await Task.sleep(for: .milliseconds(25))
            guard run == runs, attached else { return .interrupted }
        }
        let value = TextDelivery.value(of: field)
        if value?.hashValue == valueAtAttach {
            // Nothing changed in a second: the key presses are not reaching this field. Nothing counts as typed,
            // so the stop delivers everything, and nothing is ever taken back from a field that never got it.
            Diagnostics.dictation.notice("live typing: the field did not take the key presses, the words wait for the stop")
            typing.disown()
            attached = false; self.field = nil; leftSpot = nil; refused = pid; runs += 1
            typedAnything = false
            return .dead
        }
        if let value, Self.letters(value).contains(Self.letters(typing.typed).suffix(40)) {
            // The words are in its text, only not where it says the cursor is: it cannot be read.
            sight = .blind
            Diagnostics.dictation.notice("live typing: the field does not report its cursor, typing unchecked")
            return .blind
        }
        leave("the field changed the typed words")
        return .changed
    }

    /// Whether the typed characters are in the field right before the cursor, in a field that showed the first
    /// words there (`look`), before any of them is taken back or more are typed behind them. The app may not have
    /// shown the last key presses yet, so this waits for it up to 200 ms.
    private func owns(_ edits: [LiveTyping.Edit]) async -> Bool {
        // Before a deletion, and before more words too: nothing may be deleted while the person speaks, so words
        // typed behind a cursor that moved would stay there until the stop.
        guard !edits.isEmpty, !typing.typed.isEmpty, let field, sight == .readable else { return true }
        let run = runs
        for _ in 0..<8 {
            if let before = textBeforeCursor(field), Self.holds(before, typing.typed) { return true }
            try? await Task.sleep(for: .milliseconds(25))
            guard run == runs else { return false }
        }
        return false
    }

    /// Reads the field back after the last key presses: true when it ends, at the cursor, with the typed text.
    private func verify() async -> Bool {
        guard let field, !typing.typed.isEmpty, sight == .readable else { return false }
        for _ in 0..<16 {
            guard let before = textBeforeCursor(field) else { return false }
            if Self.holds(before, typing.typed) {
                if let range = TextDelivery.selectionRange(field), before.hasSuffix(typing.typed) {
                    TextDelivery.lastInsertion = (field, range.location - typing.typed.utf16.count, typing.typed)
                }
                return true
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// The text right before the cursor, enough to hold the typed words even where the field added characters of
    /// its own; nil when the app does not report it or text is selected.
    private func textBeforeCursor(_ field: AXUIElement) -> String? {
        guard let range = TextDelivery.selectionRange(field), range.length == 0, range.location >= 0 else { return nil }
        let length = min(typing.typed.utf16.count, Self.checked) * 2 + 200
        return Self.text(of: field, from: max(0, range.location - length), to: range.location)
    }

    /// The field's text in a range. Asks for the range alone where the app can give it, so a terminal's whole
    /// scrollback is not read for every check.
    private static func text(of field: AXUIElement, from start: Int, to end: Int) -> String? {
        guard start >= 0, end >= start else { return nil }
        if end == start { return "" }
        var wanted = CFRange(location: start, length: end - start)
        if let parameter = AXValueCreate(.cfRange, &wanted) {
            var text: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(field, kAXStringForRangeParameterizedAttribute as CFString, parameter, &text) == .success,
               let text = text as? String { return text }
        }
        guard let value = TextDelivery.value(of: field) else { return nil }
        let source = value as NSString
        guard end <= source.length else { return nil }
        return source.substring(with: NSRange(location: start, length: end - start))
    }

    /// Whether `before` (the field's text up to the cursor) ends with `typed`: every character of it (the newest
    /// `checked`), in order, the last one right at the cursor. Case and the kind of quote are not compared (a field
    /// with smart quotes writes ’ for ', one that capitalizes sentences changes a first letter), a line break
    /// counts as a space, and the field may hold marks and spaces of its own between them (a terminal program wraps
    /// a long line with its border and indent), though none after the last. It may never hold fewer characters
    /// than were typed: then a backspace for each typed character would reach into text that was there before.
    static func holds(_ before: String, _ typed: String) -> Bool { match(before, typed) != nil }

    /// What of `before` is left in front of the typed words when it ends with them (see `holds`); nil when it
    /// does not.
    static func match(_ before: String, _ typed: String) -> ArraySlice<Character>? {
        func fold(_ character: Character) -> String {
            if character.isWhitespace { return " " }
            switch character {
            case "’", "‘": return "'"
            case "“", "”": return "\""
            default: return character.lowercased()
            }
        }
        var field = Array(before)[...]
        var letters = 0, atCursor = true
        for character in typed.suffix(checked).reversed() {
            let wanted = fold(character)
            // Nothing of the field's own may sit between the last typed character and the cursor: a backspace
            // would take that first.
            while !atCursor, let last = field.last, fold(last) != wanted, !last.isLetter, !last.isNumber { field.removeLast() }
            guard let last = field.last, fold(last) == wanted else { return nil }
            field.removeLast()
            atCursor = false
            if character.isLetter || character.isNumber { letters += 1 }
        }
        return letters > 0 ? field : nil
    }

    /// Whether the field's text is the typed text, character for character; only case and the kind of quote may
    /// differ (a field's smart quotes and its own capital).
    static func same(_ field: String, _ typed: String) -> Bool {
        func fold(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
                .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
        }
        return fold(field) == fold(typed)
    }

    static func letters(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// One key press of an edit, and the text in the field after it. `whole`: the field then ends on a whole word,
    /// so a run of presses may end here.
    struct Press: Equatable {
        var key: CGKeyCode
        var text: [UniChar]?
        var after: String
        var whole: Bool
    }

    /// The key presses that carry out `edits` on a field holding `typed`: one Backspace for each character taken
    /// back, and text in pieces a single key event can carry (20 UTF-16 units; at most 16 here), cut after a space
    /// where there is one.
    static func presses(_ edits: [LiveTyping.Edit], from typed: String) -> [Press] {
        var field = Array(typed), presses: [Press] = []
        for edit in edits {
            switch edit {
            case .delete(let count):
                for _ in 0..<min(count, field.count) {
                    let removed = field.removeLast()
                    presses.append(Press(key: 51, text: nil, after: String(field), whole: field.isEmpty || field.last == " " || removed == " "))
                }
            case .type(let text):
                let characters = Array(text)
                var index = 0
                while index < characters.count {
                    var end = index, units = 0
                    while end < characters.count, units + characters[end].utf16.count <= 16 { units += characters[end].utf16.count; end += 1 }
                    if end == index { end = index + 1 }
                    if end < characters.count, characters[end] != " ", let space = characters[index..<end].lastIndex(of: " ") { end = space + 1 }
                    field += characters[index..<end]
                    let whole = end == characters.count || characters[end - 1] == " " || characters[end] == " "
                    presses.append(Press(key: 0, text: Array(String(characters[index..<end]).utf16), after: String(field), whole: whole))
                    index = end
                }
            }
        }
        return presses
    }

    /// Posts the edits. Focus and the modifier keys are checked right before the first key press, and again after
    /// every `burst` presses once the field ends on a whole word, with nothing awaited between a check and its
    /// presses. Returns whether every key press went out. When the check fails before the first, nothing is sent
    /// and nothing changes; when it fails later, the words are left as they really are in the field. An app that
    /// does not answer is asked again for a moment mid-edit, and with `patient` (the stop) before the first press too.
    private func send(_ edits: [LiveTyping.Edit], patient: Bool = false) async -> Bool {
        let presses = Self.presses(edits, from: typing.typed)
        guard !presses.isEmpty else { return true }
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let run = runs
        defer { sending = nil }
        var sinceCheck = 0
        for (index, press) in presses.enumerated() {
            if index == 0 || (sinceCheck >= Self.burst && presses[index - 1].whole) {
                if index > 0 { try? await Task.sleep(for: .milliseconds(2)) }
                var state = run == runs ? focus() : .gone
                // Mid-edit, a busy app gets a moment to answer before the words are given up.
                for _ in 0..<5 where (index > 0 || patient) && state == .unknown && run == runs {
                    try? await Task.sleep(for: .milliseconds(20))
                    state = focus()
                }
                guard run == runs, state == .here, !Self.modifiersHeld() else {
                    if index > 0, run == runs { leave("focus moved while typing") }
                    return false
                }
                sinceCheck = 0
            }
            for event in Self.keyEvents(press.key, text: press.text, source: source) { Self.post(event) }
            if let text = press.text { pressed.typed += text.count } else { pressed.back += 1 }
            sending = press.after
            typedAnything = true
            sinceCheck += 1
        }
        return true
    }

    /// The down and up events of one key press: no modifier, and marked as Mouthy's own so its key tap does not
    /// take them for the person typing.
    static func keyEvents(_ key: CGKeyCode, text: [UniChar]?, source: CGEventSource) -> [CGEvent] {
        [true, false].compactMap { down in
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return nil }
            event.flags = []
            if let text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
            event.setIntegerValueField(.eventSourceUserData, value: ReturnKeyTap.syntheticMarker)
            return event
        }
    }
}
