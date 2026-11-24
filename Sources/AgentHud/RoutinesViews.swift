import AgentHudCore
import AppKit
import SwiftUI

// MARK: - The tab in the control panel

struct RoutinesActions {
    var newRoutine: () -> Void = {}
    var edit: (String) -> Void = { _ in }
    var delete: (String) -> Void = { _ in }
    var openFile: () -> Void = {}
}

/// "Routines" tab: the list, the pause switch and the problems found in the file.
struct RoutinesTab: View {
    @ObservedObject var controller: RoutineController
    @ObservedObject var settings: Settings
    var actions = RoutinesActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !controller.problems.isEmpty { problemsBox }
            HStack(spacing: 8) {
                PanelButton(title: "New routine…", symbol: "plus", action: actions.newRoutine)
                PanelButton(title: "Open file", symbol: "doc.text", action: actions.openFile)
            }
            Card {
                BrandToggleRow(title: "Pause all routines", hint: "Nothing starts by itself while this is on",
                               isOn: Binding(get: { !settings.routinesEnabled }, set: { settings.routinesEnabled = !$0 }))
                    .padding(.vertical, 3)
            }
            if let m = controller.message {
                Text(m).font(Brand.body(11)).foregroundStyle(Brand.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(index: 1, title: "Routines")
                let rows = controller.rows()
                Card {
                    if rows.isEmpty {
                        Text("No routines yet. A routine is a saved prompt that Agent HUD starts by itself on a schedule, or when you press Run now.")
                            .font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            if i > 0 { Rectangle().fill(Brand.line).frame(height: 1) }
                            RoutineRowView(row: row,
                                           toggle: { controller.setEnabled(row.id, $0) },
                                           run: { controller.runNow(row.id) },
                                           edit: { actions.edit(row.id) },
                                           delete: { actions.delete(row.id) })
                        }
                    }
                }
            }
            Text("Routines run only while Agent HUD is open and the Mac is awake. Nothing is approved in advance: the agent asks you as in any session.")
                .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var problemsBox: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Brand.warning)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(controller.problems.enumerated()), id: \.offset) { _, p in
                    Text(p).font(Brand.body(11)).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.warningSoft))
    }
}

private struct RoutineRowView: View {
    let row: RoutineRow
    let toggle: (Bool) -> Void
    let run: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(row.name).font(Brand.body(13, .medium)).foregroundStyle(row.enabled ? Brand.ink : Brand.inkSubtle)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("", isOn: Binding(get: { row.enabled }, set: toggle)).toggleStyle(BrandSwitch()).labelsHidden()
            }
            Text(row.schedule + (row.next.map { " · next: \($0)" } ?? ""))
                .font(Brand.body(11)).foregroundStyle(Brand.inkMuted).lineLimit(1).truncationMode(.tail)
            HStack(spacing: 6) {
                Text(row.last).font(Brand.body(11, .medium)).foregroundStyle(tint).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                GhostButton(title: "Run now", symbol: "play.fill", tone: Brand.accentText, action: run)
                    .fixedSize()
                    .disabled(row.running)
                Menu {
                    Button("Edit…", action: edit)
                    Button("Delete…", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Brand.inkMuted)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Edit or delete")
            }
        }
        .padding(.vertical, 9)
    }

    private var tint: Color {
        switch row.lastTone {
        case .neutral: return Brand.inkSubtle
        case .accent: return Brand.accentText
        case .success: return Brand.success
        case .warning: return Brand.warning
        case .danger: return Brand.danger
        }
    }
}

// MARK: - The editor

@MainActor
final class RoutineEditorModel: ObservableObject {
    enum Kind: Hashable { case daily, every, manual }

    /// Nil: a new routine.
    let editingId: String?
    @Published var name: String
    @Published var prompt: String
    @Published var folder: String
    @Published var recent: [String]
    @Published var kind: Kind
    @Published var hour: Int
    @Published var minute: Int
    @Published var weekdays: Set<Int>
    @Published var hours: Int
    @Published var catchUp: Bool
    @Published var notify: Bool
    @Published var enabled: Bool
    /// Problems are listed once the person tried to save.
    @Published var showProblems = false
    /// A reason from outside the form (the file cannot be written).
    @Published var saveError: String?

    /// Carried over so that a save does not lose the fields this version does not know.
    private let extra: [JSONObject.Entry]

    init(routine: Routine?, recent: [String] = []) {
        editingId = routine?.id
        name = routine?.name ?? ""
        prompt = routine?.prompt ?? ""
        folder = routine?.folder ?? ""
        self.recent = recent
        catchUp = routine?.catchUp ?? true
        notify = routine?.notify ?? true
        enabled = routine?.enabled ?? true
        extra = routine?.extra ?? []
        switch routine?.schedule ?? .dailyDefault {
        case .daily(let h, let m, let days):
            kind = .daily; hour = h; minute = m; weekdays = days; hours = 4
        case .every(let n):
            kind = .every; hour = 9; minute = 0; weekdays = []; hours = n
        case .manual:
            kind = .manual; hour = 9; minute = 0; weekdays = []; hours = 4
        }
    }

    var schedule: RoutineSchedule {
        switch kind {
        case .daily: return .daily(hour: hour, minute: minute, weekdays: weekdays)
        case .every: return .every(hours: hours)
        case .manual: return .manual
        }
    }

    /// The routine as typed; a new one gets its id from the name when `takenIds` is given.
    func routine(takenIds: Set<String> = []) -> Routine {
        let id = editingId ?? Routine.makeId(from: name, taken: takenIds)
        return Routine(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines), prompt: prompt, folder: folder,
                       enabled: enabled, schedule: schedule, catchUp: catchUp, notify: notify, extra: extra)
    }

    var problems: [String] { routine().problems() }

    var promptCount: Int { prompt.count }
    var promptOver: Bool { prompt.count > Routine.maxPromptLength }

    /// A Date carrying the chosen hour and minute, for the system time field.
    var timeDate: Date {
        get { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() }
        set {
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            hour = c.hour ?? hour
            minute = c.minute ?? minute
        }
    }
}

enum RoutineEditorMetrics {
    static let width: CGFloat = 500
    static let height: CGFloat = 780
}

struct RoutineEditorActions {
    var choose: () -> Void = {}
    var save: () -> Void = {}
    var cancel: () -> Void = {}
    var openFile: () -> Void = {}
}

struct RoutineEditorView: View {
    @ObservedObject var model: RoutineEditorModel
    var actions = RoutineEditorActions()
    /// The window's height; the render check uses a taller one to show every section at once.
    var height: CGFloat = RoutineEditorMetrics.height

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.editingId == nil ? "New routine" : "Edit routine").font(Brand.display(22)).foregroundStyle(Brand.ink)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    nameSection
                    promptSection
                    folderSection
                    scheduleSection
                    optionsSection
                }
                .padding(.trailing, 2)
            }

            let problems = model.problems
            if model.showProblems, !problems.isEmpty || model.saveError != nil {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(problems + [model.saveError].compactMap { $0 }, id: \.self) { p in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11)).foregroundStyle(Brand.danger)
                            Text(p).font(Brand.body(12)).foregroundStyle(Brand.ink).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.dangerSoft))
            }

            HStack(spacing: 8) {
                Text("Every action that needs approval asks you first.").font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                Spacer(minLength: 8)
                Button("Cancel", action: actions.cancel).keyboardShortcut(.cancelAction)
                Button("Save", action: actions.save).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: RoutineEditorMetrics.width, height: height, alignment: .topLeading)
        .background(Brand.bg)
    }

    private func field<Content: View>(_ content: Content, invalid: Bool = false) -> some View {
        content
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusLg).strokeBorder(invalid ? Brand.danger : Brand.line, lineWidth: 1))
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 1, title: "Name")
            field(TextField("Morning report", text: $model.name).textFieldStyle(.plain).font(Brand.body(13)),
                  invalid: model.showProblems && model.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(index: 2, title: "Prompt")
                Spacer()
                Text("\(model.promptCount) / \(Routine.maxPromptLength)")
                    .font(Brand.mono(10)).foregroundStyle(model.promptOver ? Brand.danger : Brand.inkSubtle)
            }
            field(TextEditor(text: $model.prompt).font(Brand.body(12)).scrollContentBackground(.hidden)
                .frame(height: 100),
                  invalid: model.showProblems && (model.promptOver || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        }
    }

    private var folderSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 3, title: "Folder")
            Card {
                HStack(spacing: 8) {
                    Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Brand.inkMuted)
                    Text(model.folder.isEmpty ? "The Assistant's folder" : HookSetup.tilde(model.folder))
                        .font(Brand.mono(11)).foregroundStyle(model.folder.isEmpty ? Brand.inkSubtle : Brand.ink)
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    GhostButton(title: "Choose…", symbol: "ellipsis", action: actions.choose)
                }
                .padding(.vertical, 6)
                if !model.recent.isEmpty || !model.folder.isEmpty {
                    Rectangle().fill(Brand.line).frame(height: 1)
                    ScrollView {
                        VStack(spacing: 0) {
                            if !model.folder.isEmpty {
                                Button { model.folder = "" } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10)).foregroundStyle(Brand.inkMuted)
                                        Text("Use the Assistant's folder").font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
                                        Spacer()
                                    }
                                    .frame(height: RecentFolderRow.height).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            ForEach(model.recent, id: \.self) { path in
                                RecentFolderRow(path: path, selected: path == model.folder) { model.folder = path }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: min(CGFloat(model.recent.count + (model.folder.isEmpty ? 0 : 1)), 3) * RecentFolderRow.height + 8)
                }
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 4, title: "Schedule")
            BrandSegmented(options: [(RoutineEditorModel.Kind.daily, "Daily"), (.every, "Every N hours"), (.manual, "Manual")],
                           selection: $model.kind)
            Card {
                switch model.kind {
                case .daily:
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("At").font(Brand.body(13)).foregroundStyle(Brand.ink)
                            DatePicker("", selection: Binding(get: { model.timeDate }, set: { model.timeDate = $0 }),
                                       displayedComponents: .hourAndMinute)
                                .labelsHidden().fixedSize()
                            Spacer()
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 4) {
                                ForEach(1...7, id: \.self) { d in WeekdayChip(day: d, on: model.weekdays.contains(d)) {
                                    if model.weekdays.contains(d) { model.weekdays.remove(d) } else { model.weekdays.insert(d) }
                                } }
                            }
                            Text(model.weekdays.isEmpty || model.weekdays.count == 7 ? "Every day. Pick days to limit it."
                                 : RoutineText.describe(model.schedule))
                                .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                        }
                    }
                    .padding(.vertical, 12)
                case .every:
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Text("Every").font(Brand.body(13)).foregroundStyle(Brand.ink)
                            Stepper(value: $model.hours, in: 1...24) {
                                Text("\(model.hours) \(model.hours == 1 ? "hour" : "hours")")
                                    .font(Brand.mono(12, medium: true)).foregroundStyle(Brand.ink)
                            }
                            .fixedSize()
                            Spacer()
                        }
                        Text("Counted from the last run, or from the moment the routine was enabled.")
                            .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                    }
                    .padding(.vertical, 12)
                case .manual:
                    Text("It runs only when you press Run now.").font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(index: 5, title: "Options")
            Card {
                BrandToggleRow(title: "Enabled", isOn: $model.enabled)
                if model.kind != .manual {
                    Rectangle().fill(Brand.line).frame(height: 1)
                    BrandToggleRow(title: "Catch up", hint: "If Agent HUD was closed or the Mac asleep at the time, run once when it is back (within 12 hours)",
                                   isOn: $model.catchUp)
                }
                Rectangle().fill(Brand.line).frame(height: 1)
                BrandToggleRow(title: "Notify", hint: "Tell me when it needs me, finishes or fails", isOn: $model.notify)
            }
        }
    }
}

private struct WeekdayChip: View {
    let day: Int
    let on: Bool
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            Text(RoutineText.dayNames[day - 1])
                .font(Brand.mono(10.5, medium: on))
                .frame(maxWidth: .infinity).frame(height: 26)
                .foregroundStyle(on ? Brand.accentText : Brand.inkMuted)
                .background(RoundedRectangle(cornerRadius: Brand.radiusSm).fill(on ? Brand.accentSoft : Brand.surfaceSunken))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The editor window

/// Opens the editor in its own window, like the "New session" window.
@MainActor
final class RoutineEditorController: NSObject {
    private let app: AppModel
    private var window: NSWindow?
    private var model: RoutineEditorModel?

    init(app: AppModel) { self.app = app }

    func show(editing routine: Routine?) {
        window?.close()
        let model = RoutineEditorModel(routine: routine, recent: app.recentProjects)
        if let f = routine?.folder, !f.isEmpty, !model.recent.contains(f) { model.recent.insert(f, at: 0) }
        self.model = model
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: RoutineEditorMetrics.width, height: RoutineEditorMetrics.height),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = routine == nil ? "New routine" : "Edit routine"
        w.isReleasedWhenClosed = false
        let actions = RoutineEditorActions(
            choose: { [weak self] in self?.chooseFolder() },
            save: { [weak self] in self?.save() },
            cancel: { [weak self] in self?.window?.close() },
            openFile: { [weak self] in self?.app.routines.openFile() })
        w.contentView = NSHostingView(rootView: RoutineEditorView(model: model, actions: actions).tint(Brand.accent))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func chooseFolder() {
        guard let model, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder the routine works in"
        if !model.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: model.folder, isDirectory: true) }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                model.folder = url.path
                if !model.recent.contains(url.path) { model.recent.insert(url.path, at: 0) }
            }
        }
    }

    private func save() {
        guard let model else { return }
        model.showProblems = true
        model.saveError = nil
        let taken = Set(app.routines.routines.map(\.id))
        let routine = model.routine(takenIds: taken)
        guard routine.problems().isEmpty else { return }
        do {
            try app.routines.save(routine)
            window?.close()
        } catch {
            model.saveError = "routines.json has a problem that must be fixed by hand first (use Open file in the Routines tab)."
        }
    }
}
