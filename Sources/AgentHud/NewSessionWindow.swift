import AgentHudCore
import AppKit
import SwiftUI

/// What the "New session" window shows. The real window fills it from the app model; the render check uses fixed values.
@MainActor
final class NewSessionModel: ObservableObject {
    @Published var folder: String
    @Published var recent: [String]
    @Published var message: String
    /// Why the session was not started.
    @Published var problem: String?
    /// The problem is about the hooks: the window offers the setup window.
    @Published var offersSetup = false

    /// Which tab is shown; the controller reacts to a change (loads the list, refreshes the problem line).
    @Published var tab: NewSessionTab = .new {
        didSet { if tab != oldValue { onTabChange?(tab) } }
    }
    var onTabChange: ((NewSessionTab) -> Void)?
    @Published var past: [PastSession] = []
    @Published var loadingPast = false
    @Published var search = ""
    @Published var selectedPast: String?
    /// "Now" for the relative times; fixed in the render check.
    var now = Date()

    init(folder: String = "", recent: [String] = [], message: String = "", problem: String? = nil, offersSetup: Bool = false,
         tab: NewSessionTab = .new, past: [PastSession] = [], loadingPast: Bool = false, search: String = "", selectedPast: String? = nil) {
        self.folder = folder
        self.recent = recent
        self.message = message
        self.problem = problem
        self.offersSetup = offersSetup
        self.tab = tab
        self.past = past
        self.loadingPast = loadingPast
        self.search = search
        self.selectedPast = selectedPast
    }

    var canStart: Bool { !folder.isEmpty }

    /// The list after the search: title, project name and path are matched, case-insensitively.
    var visiblePast: [PastSession] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return past }
        return past.filter {
            $0.title.lowercased().contains(q) || ProjectNames.displayName(cwd: $0.cwd).lowercased().contains(q)
                || $0.cwd.lowercased().contains(q)
        }
    }

    /// Sessions by project, the project with the newest session first. The list is already newest first.
    var groups: [(cwd: String, sessions: [PastSession])] {
        var out: [(cwd: String, sessions: [PastSession])] = []
        for s in visiblePast {
            if let i = out.firstIndex(where: { $0.cwd == s.cwd }) { out[i].sessions.append(s) } else { out.append((s.cwd, [s])) }
        }
        return out
    }
}

enum NewSessionTab: Int { case new, continueSession }

struct NewSessionActions {
    var choose: () -> Void = {}
    var start: () -> Void = {}
    var openSetup: () -> Void = {}
    var cancel: () -> Void = {}
    var continueSelected: () -> Void = {}
}

enum NewSessionMetrics {
    static let width: CGFloat = 460
    static let height: CGFloat = 520
}

struct NewSessionView: View {
    @ObservedObject var model: NewSessionModel
    var actions = NewSessionActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New session").font(Brand.display(22)).foregroundStyle(Brand.ink)
                Text("Claude Code runs inside Agent HUD: you chat in the session card and approve its actions there.")
                    .font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("", selection: $model.tab) {
                Text("New").tag(NewSessionTab.new)
                Text("Continue").tag(NewSessionTab.continueSession)
            }
            .pickerStyle(.segmented).labelsHidden()

            if model.tab == .new { newContent } else { continueContent }

            if let problem = model.problem {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Brand.warning)
                    Text(problem).font(Brand.body(12)).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.offersSetup {
                        Button("Open setup", action: actions.openSetup).controlSize(.small).fixedSize()
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.warningSoft))
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(model.tab == .new ? "Every action that needs approval asks you first." : "The conversation goes on where it stopped.")
                    .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                Spacer(minLength: 8)
                Button("Cancel", action: actions.cancel).keyboardShortcut(.cancelAction)
                if model.tab == .new {
                    Button("Start", action: actions.start)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStart)
                } else {
                    Button("Continue", action: actions.continueSelected)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedPast == nil)
                }
            }
        }
        .padding(20)
        .frame(width: NewSessionMetrics.width, height: NewSessionMetrics.height, alignment: .topLeading)
        .background(Brand.bg)
    }

    @ViewBuilder private var newContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(index: 1, title: "Project folder")
                Card {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Brand.inkMuted)
                        Text(model.folder.isEmpty ? "No folder chosen" : HookSetup.tilde(model.folder))
                            .font(Brand.mono(11)).foregroundStyle(model.folder.isEmpty ? Brand.inkSubtle : Brand.ink)
                            .lineLimit(1).truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        GhostButton(title: "Choose…", symbol: "ellipsis", action: actions.choose)
                    }
                    .padding(.vertical, 6)
                    if !model.recent.isEmpty {
                        Rectangle().fill(Brand.line).frame(height: 1)
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(model.recent, id: \.self) { path in
                                    RecentFolderRow(path: path, selected: path == model.folder) { model.folder = path }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .frame(height: min(CGFloat(model.recent.count), 5) * RecentFolderRow.height + 8)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(index: 2, title: "First message (optional)")
                TextField("What should the agent do?", text: $model.message, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Brand.body(12))
                    .lineLimit(3...5)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.surface))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radiusLg).strokeBorder(Brand.line, lineWidth: 1))
            }

        }
    }

    @ViewBuilder private var continueContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Brand.inkSubtle)
                TextField("Search by title or project", text: $model.search).textFieldStyle(.plain).font(Brand.body(12))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Brand.radiusLg).fill(Brand.surface))
            .overlay(RoundedRectangle(cornerRadius: Brand.radiusLg).strokeBorder(Brand.line, lineWidth: 1))

            Card {
                if model.loadingPast {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for sessions…").font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.visiblePast.isEmpty {
                    Text(model.past.isEmpty ? "No past sessions found" : "Nothing matches the search")
                        .font(Brand.body(12)).foregroundStyle(Brand.inkMuted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let groups = model.groups
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(groups, id: \.cwd) { g in
                                if groups.count > 1 { ProjectHeader(cwd: g.cwd) }
                                ForEach(g.sessions) { s in
                                    PastSessionRow(session: s, now: model.now, showsProject: groups.count == 1,
                                                   selected: s.id == model.selectedPast,
                                                   pick: { model.selectedPast = s.id },
                                                   open: { model.selectedPast = s.id; actions.continueSelected() })
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

private struct ProjectHeader: View {
    let cwd: String
    var body: some View {
        HStack(spacing: 6) {
            ProjectDot(cwd: cwd, size: 7)
            Text(ProjectNames.displayName(cwd: cwd)).font(Brand.body(11, .medium)).foregroundStyle(Brand.inkMuted).lineLimit(1)
            Text(HookSetup.tilde(cwd)).font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle)
                .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8).padding(.bottom, 2)
    }
}

private struct PastSessionRow: View {
    let session: PastSession
    let now: Date
    let showsProject: Bool
    let selected: Bool
    let pick: () -> Void
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(session.title).font(Brand.body(12, .medium)).foregroundStyle(Brand.ink).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(SessionHistory.relativeTime(session.lastActivity, now: now))
                    .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle).lineLimit(1).fixedSize()
            }
            if showsProject {
                HStack(spacing: 6) {
                    ProjectDot(cwd: session.cwd, size: 6)
                    Text(ProjectNames.displayName(cwd: session.cwd)).font(Brand.body(10, .medium)).foregroundStyle(Brand.inkMuted).lineLimit(1)
                        .layoutPriority(1)
                    Text(HookSetup.tilde(session.cwd)).font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle)
                        .lineLimit(1).truncationMode(.head).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Brand.radiusMd)
            .fill(selected ? Brand.accentSoft : (hover ? Brand.surfaceSunken : .clear)))
        .padding(.horizontal, -2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: open)
        .onTapGesture(perform: pick)
        .onHover { hover = $0 }
    }
}

struct RecentFolderRow: View {
    let path: String
    let selected: Bool
    let pick: () -> Void
    @State private var hover = false

    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: 8) {
            ProjectDot(cwd: path, size: 7)
            Text(ProjectNames.displayName(cwd: path)).font(Brand.body(12, .medium)).foregroundStyle(Brand.ink)
                .lineLimit(1).layoutPriority(1)
            Text(HookSetup.tilde((path as NSString).deletingLastPathComponent))
                .font(Brand.mono(10)).foregroundStyle(Brand.inkSubtle)
                .lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Brand.accentText) }
        }
        .padding(.horizontal, 6)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: Brand.radiusMd)
            .fill(selected ? Brand.accentSoft : (hover ? Brand.surfaceSunken : .clear)))
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .onHover { hover = $0 }
    }
}

/// The "New session" window: a regular titled window with the folder, the first message and "Start".
@MainActor
final class NewSessionController: NSObject {
    private let app: AppModel
    private let model = NewSessionModel()
    private var window: NSWindow?
    private var loadGeneration = 0

    init(model: AppModel) {
        app = model
        super.init()
        self.model.onTabChange = { [weak self] tab in
            guard let self else { return }
            self.setProblem(self.app.startRefusal())
            if tab == .continueSession { self.loadPast() }
        }
    }

    /// `folder` preselects a project; `message` explains why an earlier attempt to start was refused.
    /// `text` fills the message field (the command bar hands over what was typed).
    func show(folder: String? = nil, message: String? = nil, tab: NewSessionTab = .new, text: String? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: NewSessionMetrics.width, height: NewSessionMetrics.height),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "New session"
            w.isReleasedWhenClosed = false
            let actions = NewSessionActions(
                choose: { [weak self] in self?.chooseFolder() },
                start: { [weak self] in self?.start() },
                openSetup: { [weak self] in self?.app.openSetup(.hooks) },
                cancel: { [weak self] in self?.window?.close() },
                continueSelected: { [weak self] in self?.continueSelected() })
            w.contentView = NSHostingView(rootView: NewSessionView(model: model, actions: actions).tint(Brand.accent))
            w.center()
            window = w
        }
        model.recent = app.recentProjects
        if let text, !text.isEmpty { model.message = text }
        if let folder, !folder.isEmpty {
            model.folder = folder
        } else if model.folder.isEmpty || !FileManager.default.fileExists(atPath: model.folder) {
            model.folder = model.recent.first ?? ""
        }
        if !model.folder.isEmpty, !model.recent.contains(model.folder) { model.recent.insert(model.folder, at: 0) }
        setProblem(message ?? app.startRefusal())
        if model.tab == tab {
            if tab == .continueSession { loadPast() }
        } else {
            let keep = message
            model.tab = tab
            if let keep { setProblem(keep) }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func setProblem(_ text: String?) {
        model.problem = text
        model.offersSetup = text != nil && app.startRefusal() != nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder the session works in"
        if !model.folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: model.folder, isDirectory: true) }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.folder = url.path
                if !self.model.recent.contains(url.path) { self.model.recent.insert(url.path, at: 0) }
            }
        }
    }

    private func start() {
        guard model.canStart else { return }
        if let refusal = app.startSession(cwd: model.folder, firstMessage: model.message) {
            setProblem(refusal)
            return
        }
        model.message = ""
        model.problem = nil
        window?.close()
    }

    // MARK: - Continue tab

    /// Reads the list off the main thread; a newer call makes an older, slower one drop its result.
    private func loadPast() {
        loadGeneration += 1
        let generation = loadGeneration
        model.loadingPast = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task {
            // More than shown: sessions that are open now are taken out below.
            let found = await Task.detached(priority: .userInitiated) { SessionHistory.recent(home: home, limit: 80) }.value
            guard generation == loadGeneration else { return }
            let busy = app.sessionIdsInUse()
            model.past = Array(found.filter { !busy.contains($0.id) }.prefix(40))
            model.now = Date()
            if let id = model.selectedPast, !model.past.contains(where: { $0.id == id }) { model.selectedPast = nil }
            model.loadingPast = false
        }
    }

    private func continueSelected() {
        guard let id = model.selectedPast, let s = model.past.first(where: { $0.id == id }) else { return }
        if let refusal = app.startRefusal() { setProblem(refusal); return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: s.cwd, isDirectory: &isDir), isDir.boolValue else {
            setProblem("The project folder no longer exists: \(s.cwd)")
            return
        }
        guard SessionHistory.isPossiblyLive(s, now: Date()), let window else { resume(s); return }
        let alert = NSAlert()
        alert.messageText = "This session was active a moment ago."
        alert.informativeText = "If it is still open in an editor or terminal, continuing it here can lose messages."
        alert.addButton(withTitle: "Continue anyway")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.resume(s) }
        }
    }

    private func resume(_ s: PastSession) {
        if let refusal = app.resumePast(id: s.id, cwd: s.cwd) {
            setProblem(refusal)
            return
        }
        model.problem = nil
        model.selectedPast = nil
        window?.close()
    }
}
