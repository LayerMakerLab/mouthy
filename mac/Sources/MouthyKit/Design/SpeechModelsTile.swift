import SwiftUI
import MouthyNotch

/// A presentation-only tile: offscreen renders inject rows and never inspect or mutate model caches.
struct SpeechModelsTile: View {
    let rows: [SpeechModelRow]
    var busy = false
    var localOnly = false
    var message: String?
    var download: (SpeechModelID) -> Void = { _ in }
    var remove: (SpeechModelID) -> Void = { _ in }

    var body: some View {
        SettingsTile("Speech models", symbol: "internaldrive") {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { SettingDivider() }
                SettingRow(row.id.title, detail: "\(row.status)\n\(row.size)", controlWidth: nil) {
                    HStack(spacing: 8) {
                        if row.canRemove {
                            Button(row.id == .apple ? "Release…" : "Remove…") { remove(row.id) }
                                .buttonStyle(.compact)
                                .accessibilityLabel("\(row.id == .apple ? "Release" : "Remove") \(row.id.title)")
                        }
                        if row.canDownload {
                            Button("Download") { download(row.id) }
                                .buttonStyle(.compactProminent)
                                .disabled(localOnly)
                                .accessibilityLabel("Download \(row.id.title)")
                        }
                    }
                    .disabled(busy)
                }
            }
            SettingDivider()
            Text("Apple shares its language files with other apps. Releasing them lets macOS reclaim space; their size and removal are controlled by macOS.")
                .font(MouthyType.caption).foregroundStyle(MouthyTheme.cream2)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 10)
            if localOnly || message != nil {
                Text(message ?? "Downloads are off while network use is blocked.")
                    .font(MouthyType.caption).foregroundStyle(MouthyTheme.glow)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 10)
                    .accessibilityLabel(message ?? "Downloads are off while network use is blocked.")
            }
        }
    }
}

struct SpeechModelsSettings: View {
    @ObservedObject var model: AppModel
    @State private var rows = SpeechModelID.all.map { SpeechModelRow(id: $0, status: "Checking…", size: "", canDownload: false) }
    @State private var pendingRemoval: SpeechModelID?
    @State private var showMessage = false
    @State private var activeModel: SpeechModelID?

    var body: some View {
        SpeechModelsTile(rows: displayedRows, busy: model.busy || model.setupBusy, localOnly: model.preferences.localOnly,
                         message: showMessage ? model.status : nil,
                         download: { id in showMessage = true; activeModel = id; model.installModel(id) },
                         remove: { pendingRemoval = $0 })
            .task(id: model.preferences.locale) { await refresh() }
            .onChange(of: model.setupBusy) { _, busy in
                if !busy { Task { await refresh() } }
            }
            .confirmationDialog(pendingRemoval == .apple ? "Release these Apple speech language files?" : "Move this downloaded model to Trash?",
                                isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
                                titleVisibility: .visible, presenting: pendingRemoval) { id in
                Button(id == .apple ? "Release language files" : "Move model to Trash", role: .destructive) {
                    showMessage = true
                    activeModel = id
                    model.removeModel(id)
                    pendingRemoval = nil
                }
            } message: { id in
                Text(id == .apple ? "macOS may keep files used by other apps. Space is not necessarily freed immediately." :
                        id == .parakeet && !SherpaParakeet.preferred ? "Includes the vocabulary model. Other apps using the shared Parakeet cache will need to download it again." :
                        "Download this model again before using it offline.")
            }
    }

    private var displayedRows: [SpeechModelRow] {
        rows.map { row in
            var row = row
            if model.setupBusy && row.id == activeModel { row.status = model.status }
            return row
        }
    }

    private func refresh() async {
        let locale = model.speechLocale(model.preferences.locale)
        let local = await Task.detached(priority: .utility) { SpeechModelCatalog.localRows() }.value
        let apple = await SpeechModelCatalog.appleRow(locale: locale)
        guard !Task.isCancelled else { return }
        rows = [apple] + local
    }
}
