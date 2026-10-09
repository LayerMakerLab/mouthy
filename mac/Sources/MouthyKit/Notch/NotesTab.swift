import AppKit
import Combine
import MouthyNotch
import SwiftUI

/// Todos and one quick note, saved as you type. The mic button dictates a todo.
@MainActor final class NotesTab: ObservableObject, NotchTab {
    static let shared = NotesTab()
    struct Todo: Codable, Identifiable, Equatable { var id = UUID(); var text: String; var done = false }
    struct Document: Codable { var todos: [Todo] = []; var note = "" }

    let id = "mouthy.notes"
    let title = "Todos & notes"
    let symbolName = "checklist"
    @Published var todos: [Todo] { didSet { save() } }
    @Published var note: String { didSet { save() } }
    @Published var draft = ""
    let dictation = DictationSession(configuration: DictationConfiguration(engine: .apple, maximumDuration: .seconds(30)))

    private init() {
        let saved = NotchFile.load(Document.self, "notes.json") ?? Document()
        todos = saved.todos; note = saved.note
        // Finished dictations become todos, whether stopped by hand or by the time limit.
        finishedLink = dictation.$phase.sink { [weak self] phase in
            if case let .finished(text) = phase { Task { @MainActor in self?.add(text) } }
        }
    }
    private var finishedLink: AnyCancellable?

    var badge: NotchBadge? {
        let open = todos.filter { !$0.done }.count
        return open == 0 ? nil : NotchBadge(count: open)
    }

    func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        todos.insert(Todo(text: trimmed), at: 0)
        NotchHub.shared.tabDidChange(id: id)
    }
    /// A spoken note: one more line at the end of the note.
    func addNote(_ text: String) {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        note = note.isEmpty || note.hasSuffix("\n") ? note + line : note + "\n" + line
        NotchHub.shared.tabDidChange(id: id)
    }
    func toggle(_ todo: Todo) {
        guard let index = todos.firstIndex(of: todo) else { return }
        todos[index].done.toggle()
        NotchHub.shared.tabDidChange(id: id)
    }
    func clearDone() { todos.removeAll(where: \.done); NotchHub.shared.tabDidChange(id: id) }

    func dictateTodo() {
        if dictation.isRunning { Task { _ = await dictation.stop() }; return }
        Task {
            NotchHub.shared.presentDictation(session: dictation, target: "Todos")
            try? await dictation.start()
        }
    }

    private func save() { NotchFile.save(Document(todos: todos, note: note), "notes.json") }

    func makeBody() -> AnyView { AnyView(NotesView(model: self)) }
}

struct NotesView: View {
    @ObservedObject var model: NotesTab
    @ObservedObject var dictation: DictationSession
    init(model: NotesTab) { self.model = model; dictation = model.dictation }

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    NotchField(prompt: "Add a todo", text: $model.draft) { model.add(model.draft); model.draft = "" }
                    Button { model.dictateTodo() } label: {
                        Image(systemName: dictation.isRunning ? "stop.fill" : "mic.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(dictation.isRunning ? MouthyTheme.night : MouthyTheme.glow)
                            .contentTransition(.symbolEffect(.replace))
                            .frame(width: 26, height: 26)
                            .background {
                                if dictation.isRunning { Circle().fill(MouthyTheme.ember) }
                            }
                            .modifier(OptionalCircleGlass(enabled: !dictation.isRunning))
                            .contentShape(Circle())
                    }
                    .buttonStyle(NotchPressStyle())
                    .help(dictation.isRunning ? "Finish the todo" : "Dictate a todo")
                    .accessibilityLabel(dictation.isRunning ? "Finish the todo" : "Dictate a todo")
                    if model.todos.contains(where: \.done) {
                        Button { model.clearDone() } label: {
                            Image(systemName: "checklist.checked").font(.system(size: 13, weight: .semibold)).foregroundStyle(MouthyTheme.cream2)
                                .frame(width: 26, height: 26).contentShape(Circle())
                        }
                        .buttonStyle(NotchPressStyle())
                        .help("Clear done").accessibilityLabel("Clear done todos")
                    }
                }
                if model.todos.isEmpty {
                    NotchEmptyState(pose: .sleep, title: "Nothing to do", message: "Type a todo, or press the mic and say it.")
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(model.todos) { todo in TodoRow(todo: todo) { model.toggle(todo) } }
                        }
                    }
                    .notchScrollFade()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                TabHeader(title: "Note")
                NoteEditor(text: $model.note, placeholder: "Jot something down…")
                    .overlay(alignment: .topLeading) {
                        if model.note.isEmpty {
                            Text("Jot something down…").font(.system(size: 14)).foregroundStyle(MouthyTheme.cream3)
                                .padding(.leading, 2).padding(.top, 2).allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .smokedGlass(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .frame(width: 200)
        }
    }
}

struct OptionalCircleGlass: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.smokedGlass(Circle()) } else { content }
    }
}

struct TodoRow: View {
    let todo: NotesTab.Todo
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: todo.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.done ? MouthyTheme.glow : MouthyTheme.cream2)
                    .contentTransition(.symbolEffect(.replace))
                Text(todo.text).font(.system(size: 14))
                    .strikethrough(todo.done, color: MouthyTheme.cream2)
                    .foregroundStyle(todo.done ? MouthyTheme.cream2 : MouthyTheme.cream)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .hoverRow()
        }
        .buttonStyle(.plain)
        .accessibilityValue(todo.done ? "Done" : "Open")
    }
}

/// The quick note: an AppKit text view so selection and caret take the giraffe colours (orange selection,
/// mic-glow caret) instead of the system's blue.
struct NoteEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    static let selection = NSColor(srgbRed: 0xE0 / 255, green: 0x8A / 255, blue: 0x2E / 255, alpha: 0.35)
    static let caret = NSColor(srgbRed: 1, green: 0xB5 / 255, blue: 0x47 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0xF6 / 255, green: 0xE3 / 255, blue: 0xC1 / 255, alpha: 1)

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        Self.style(view, placeholder: placeholder)
        view.delegate = context.coordinator
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    /// Giraffe colours on an NSTextView: transparent, cream ink, orange selection, glow caret.
    static func style(_ view: NSTextView, placeholder: String) {
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 12.5)
        view.textColor = ink
        view.insertionPointColor = caret
        view.selectedTextAttributes = [.backgroundColor: selection, .foregroundColor: ink]
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 2
        view.setAccessibilityLabel("Note")
        view.setAccessibilityPlaceholderValue(placeholder)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}
