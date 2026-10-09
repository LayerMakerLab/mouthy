import SwiftUI
import AppKit
import MouthyCore
import MouthyNotch

/// Words to know (glass chips), Teach a word, exact replacements and spoken commands.
/// Each add or remove saves at once; there is no Save button.
struct VocabularyView: View {
    @ObservedObject var model: AppModel
    @State private var newWord = ""
    @State private var heard = ""
    @State private var meant = ""
    @State private var phrase = ""
    @State private var replacement = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var words: [String] { VocabularyEditing.words(model.preferences.vocabulary) }
    private var motion: Animation { MouthyMotion.resolve(MouthyMotion.select, reduceMotion: reduceMotion) }

    var body: some View {
        PageScroll {
            PageHeader("Vocabulary", subtitle: "Names and terms I should spell right.")
            wordsTile
            teachTile
            replacementsTile
            Tile(padding: 0) {
                SettingRow("Spoken commands", detail: "Punctuation, “new line” and “scratch that”.", controlWidth: nil) {
                    Toggle("Spoken commands", isOn: $model.preferences.punctuationCommands).labelsHidden().toggleStyle(.warmSwitch)
                }
                .padding(.horizontal, 20).padding(.vertical, 4)
            }
        }
        .disabled(model.busy)
    }

    // MARK: Words

    private var wordsTile: some View {
        Tile {
            VStack(alignment: .leading, spacing: 14) {
                TileHeader("Words to know", symbol: "text.book.closed") {
                    if !words.isEmpty {
                        Text("\(words.count)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(MouthyTheme.cream2)
                            .contentTransition(.numericText(value: Double(words.count)))
                    }
                }
                if words.isEmpty {
                    HStack(spacing: 14) {
                        MascotView(pose: .sleep, size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No words yet").font(MouthyType.headline).foregroundStyle(MouthyTheme.cream)
                            Text(model.preferences.learnWords
                                 ? "I also learn from corrections you make right after dictating."
                                 : "Teach me a word below and I'll spell it right from now on.")
                                .font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if model.preferences.learnWords {
                    Text("I also learn from corrections you make right after dictating.")
                        .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                }
                GlassEffectContainer(spacing: 8) {
                    FlowLayout(spacing: 8) {
                        ForEach(words, id: \.self) { word in
                            WordChip(word: word) { remove(word) }
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                        MouthyField("Add word", text: $newWord) { addWord() }
                            .frame(width: 160)
                    }
                }
                .animation(motion, value: words)
            }
        }
    }

    private func addWord() {
        let updated = VocabularyEditing.adding(newWord, to: model.preferences.vocabulary)
        newWord = ""
        guard updated != model.preferences.vocabulary else { return }
        withAnimation(motion) { model.preferences.vocabulary = updated }
        model.savePreferences()
    }

    private func remove(_ word: String) {
        withAnimation(motion) { model.preferences.vocabulary = VocabularyEditing.removing(word, from: model.preferences.vocabulary) }
        model.savePreferences()
    }

    // MARK: Teach

    private var teachTile: some View {
        Tile {
            VStack(alignment: .leading, spacing: 12) {
                TileHeader("Teach a word", symbol: "graduationcap")
                Text("Tell me what I heard and what you meant. I learn the word and fix it from now on.")
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                HStack(spacing: 10) {
                    MouthyField("Heard", text: $heard) { teach() }
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
                    MouthyField("Meant", text: $meant) { teach() }
                    Button("Teach") { teach() }
                        .buttonStyle(.compactGlass)
                        .disabled(meant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func teach() {
        guard !meant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        withAnimation(motion) { model.teach(heard: heard, meant: meant) }
        heard = ""; meant = ""
    }

    // MARK: Replacements

    private var replacementsTile: some View {
        Tile {
            VStack(alignment: .leading, spacing: 12) {
                TileHeader("Replacements", symbol: "arrow.left.arrow.right")
                Text("Say a phrase, get your text. Whole phrases, any capitals.")
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                VStack(spacing: 0) {
                    ForEach(model.preferences.replacements) { rule in
                        ReplacementRow(rule: rule) { removeRule(rule) }
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                        SettingDivider()
                    }
                }
                .animation(motion, value: model.preferences.replacements)
                if model.preferences.replacements.isEmpty {
                    HStack(spacing: 10) {
                        MascotView(pose: .sleep, size: 40)
                        Text("No replacements yet. “my sig” can become your sign-off.")
                            .font(MouthyType.callout).foregroundStyle(MouthyTheme.cream2)
                    }
                    .padding(.vertical, 4)
                }
                HStack(spacing: 10) {
                    MouthyField("When I say…", text: $phrase) { addRule() }
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
                    MouthyField("Write this…", text: $replacement) { addRule() }
                    Button("Add") { addRule() }
                        .buttonStyle(.compactGlass)
                        .disabled(phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func addRule() {
        guard let rule = VocabularyEditing.replacement(phrase: phrase, replacement: replacement) else { return }
        withAnimation(motion) { model.preferences.replacements = VocabularyEditing.adding(rule, to: model.preferences.replacements) }
        phrase = ""; replacement = ""
        model.savePreferences()
    }

    private func removeRule(_ rule: Replacement) {
        withAnimation(motion) { model.preferences.replacements.removeAll { $0.id == rule.id } }
        model.savePreferences()
    }
}

/// One vocabulary word: a warm glass chip whose remove button appears on hover.
private struct WordChip: View {
    let word: String
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 6) {
            Text(word).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(MouthyTheme.cream).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(MouthyTheme.cream2)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(MouthyTheme.cream.opacity(0.10)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .frame(width: hovering ? 16 : 0)
            .help("Remove \(word)")
            .accessibilityLabel("Remove \(word)")
        }
        .padding(.leading, 12).padding(.trailing, hovering ? 6 : 12)
        .frame(height: 30)
        .mouthyGlass(Capsule(style: .circular), interactive: true)
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .contextMenu { Button("Remove “\(word)”", role: .destructive, action: remove) }
        .accessibilityElement(children: .contain)
    }
}

/// phrase → replacement, with a remove button on hover.
private struct ReplacementRow: View {
    let rule: Replacement
    let remove: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 10) {
            Text(rule.phrase).font(MouthyType.body).foregroundStyle(MouthyTheme.cream)
            Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(MouthyTheme.glow)
            Text(rule.replacement.isEmpty ? "(nothing)" : rule.replacement)
                .font(MouthyType.body).foregroundStyle(rule.replacement.isEmpty ? MouthyTheme.cream3 : MouthyTheme.cream2)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(MouthyTheme.cream2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Remove this replacement")
            .accessibilityLabel("Remove \(rule.phrase)")
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: MouthyTheme.Radius.row, style: .continuous).fill(hovering ? MouthyTheme.hoverFill : .clear))
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .animation(MouthyMotion.resolve(MouthyMotion.hover, reduceMotion: reduceMotion), value: hovering)
        .contextMenu { Button("Remove", role: .destructive, action: remove) }
    }
}
