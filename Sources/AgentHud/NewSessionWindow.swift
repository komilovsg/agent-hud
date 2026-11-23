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

    init(folder: String = "", recent: [String] = [], message: String = "", problem: String? = nil, offersSetup: Bool = false) {
        self.folder = folder
        self.recent = recent
        self.message = message
        self.problem = problem
        self.offersSetup = offersSetup
    }

    var canStart: Bool { !folder.isEmpty }
}

struct NewSessionActions {
    var choose: () -> Void = {}
    var start: () -> Void = {}
    var openSetup: () -> Void = {}
    var cancel: () -> Void = {}
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
                Text("Every action that needs approval asks you first.")
                    .font(Brand.body(11)).foregroundStyle(Brand.inkSubtle)
                Spacer(minLength: 8)
                Button("Cancel", action: actions.cancel).keyboardShortcut(.cancelAction)
                Button("Start", action: actions.start)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStart)
            }
        }
        .padding(20)
        .frame(width: NewSessionMetrics.width, height: NewSessionMetrics.height, alignment: .topLeading)
        .background(Brand.bg)
    }
}

private struct RecentFolderRow: View {
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

    init(model: AppModel) {
        app = model
        super.init()
    }

    /// `folder` preselects a project; `message` explains why an earlier attempt to start was refused.
    func show(folder: String? = nil, message: String? = nil) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: NewSessionMetrics.width, height: NewSessionMetrics.height),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "New session"
            w.isReleasedWhenClosed = false
            let actions = NewSessionActions(
                choose: { [weak self] in self?.chooseFolder() },
                start: { [weak self] in self?.start() },
                openSetup: { [weak self] in self?.app.openSetup(.hooks) },
                cancel: { [weak self] in self?.window?.close() })
            w.contentView = NSHostingView(rootView: NewSessionView(model: model, actions: actions).tint(Brand.accent))
            w.center()
            window = w
        }
        model.recent = app.recentProjects
        if let folder, !folder.isEmpty {
            model.folder = folder
        } else if model.folder.isEmpty || !FileManager.default.fileExists(atPath: model.folder) {
            model.folder = model.recent.first ?? ""
        }
        if !model.folder.isEmpty, !model.recent.contains(model.folder) { model.recent.insert(model.folder, at: 0) }
        setProblem(message ?? app.startRefusal())
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
}
