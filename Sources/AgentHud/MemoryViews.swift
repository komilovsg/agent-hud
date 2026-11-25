import AppKit
import AgentHudCore
import SwiftUI

/// The Assistant's memory in the UI: the "Remembered / Forgot" rows of its card and the "Memory" settings section.

enum MemoryFile {
    /// Opens memory.json in the person's editor; a missing file is created empty first so there is something to open.
    /// A file that exists is never touched here, broken or not.
    static func open() {
        let url = AgentHUDPaths.memoryFile
        if !FileManager.default.fileExists(atPath: url.path) { try? MemoryStore().save(to: url) }
        NSWorkspace.shared.open(url)
    }
}

/// Rows under the Assistant's card header: every save is shown here, and "Undo" takes it back.
struct MemoryNoteRows: View {
    @ObservedObject var model: AppModel
    let sessionKey: String
    let notes: [MemoryNote]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(notes.suffix(2)) { n in
                Notice(icon: n.entryId != nil ? "bookmark.fill" : "bookmark", color: .blue, text: n.text,
                       actions: n.entryId != nil ? [("Undo", { model.undoRemember(sessionKey: sessionKey, noteId: n.id) })] : [])
            }
        }
    }
}

/// The "Memory" section of the control panel. Plain values and closures, so that the render check can draw it
/// without touching the saved settings or the file.
struct MemorySettingsSection: View {
    let index: Int
    @Binding var enabled: Bool
    let entries: [MemoryEntry]
    let broken: Bool
    var delete: (String) -> Void = { _ in }
    var openFile: () -> Void = {}
    var clearAll: () -> Void = {}
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: index, title: "Memory")
            Card {
                VStack(alignment: .leading, spacing: 6) {
                    BrandToggleRow(title: "Memory", hint: "The Assistant keeps notes you ask it to remember", isOn: $enabled)
                        .padding(.top, 6)
                    Divider().overlay(Brand.line)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(broken ? "Notes: unavailable" : "Notes: \(entries.count)")
                            .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                        Spacer()
                        GhostButton(title: "Open file", symbol: "doc.text", action: openFile)
                    }
                    if broken {
                        Label("The memory file cannot be read. It is left as it is; fix it in the file.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(Brand.body(11, .medium)).foregroundStyle(Brand.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !entries.isEmpty {
                        rows
                        Divider().overlay(Brand.line)
                        if confirming {
                            HStack(spacing: 6) {
                                Text("Forget all \(entries.count) notes?").font(Brand.body(12)).foregroundStyle(Brand.ink)
                                Spacer()
                                GhostButton(title: "Cancel", symbol: "xmark") { confirming = false }
                                GhostButton(title: "Forget", symbol: "trash", tone: Brand.danger) { confirming = false; clearAll() }
                            }
                        } else {
                            GhostButton(title: "Forget everything\u{2026}", symbol: "trash", tone: Brand.danger) { confirming = true }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    /// Newest first. Past a handful of rows the list scrolls instead of growing the panel.
    @ViewBuilder private var rows: some View {
        let list = VStack(alignment: .leading, spacing: 4) {
            ForEach(entries.reversed()) { e in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: e.text).font(Brand.body(12)).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { delete(e.id) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Brand.inkSubtle)
                    }
                    .buttonStyle(.plain).help("Delete this note").accessibilityLabel("Delete note")
                }
            }
        }
        if entries.count > 6 { ScrollView { list }.frame(maxHeight: 170) } else { list }
    }
}
