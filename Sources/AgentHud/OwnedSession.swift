import AgentHudCore
import Darwin
import Foundation

/// One Claude Code session whose CLI process is started and owned by this app: a long-lived child that takes
/// user turns as JSON lines on stdin and reports everything as JSON lines on stdout. This file is the only place
/// that starts that process.
@MainActor
final class OwnedSession: ObservableObject {
    struct Config {
        /// The CLI to run; nil - not found.
        var executable: URL?
        var environment: [String: String]
        /// No output at all for this long after a message: the card says so.
        var responseTimeout: TimeInterval = 30
        /// After stdin is closed the process gets this long to leave by itself.
        var finishGrace: TimeInterval = 10
        /// After a terminate request, how long until the process is killed.
        var killGrace: TimeInterval = 3

        /// `AGENTHUD_CLAUDE_BIN` or the usual install locations; the parent environment plus the hook switch.
        static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> Config {
            let path = OwnedSessionLogic.findExecutable(
                override: environment["AGENTHUD_CLAUDE_BIN"],
                home: FileManager.default.homeDirectoryForCurrentUser.path,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) })
            return Config(executable: path.map { URL(fileURLWithPath: $0) }, environment: childEnvironment(environment))
        }

        static func childEnvironment(_ parent: [String: String]) -> [String: String] {
            var env = parent
            // The hooks forward events of this session to the HUD although no terminal or editor is behind it.
            env["AGENTHUD_ANY_HOST"] = "1"
            // Markers of a surrounding session (the app was started from an editor or a terminal session)
            // would make the child and its hooks describe the wrong host.
            for k in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_HOST_SESSION_ID", "CLAUDE_CODE_SSE_PORT"] { env[k] = nil }
            return env
        }
    }

    static let busyMessage = "The agent is still working — wait for it or interrupt"
    static let goneMessage = "This session's process has exited"
    nonisolated static let stderrLimit = 4096
    private static let loginShell = "/bin/zsh"
    /// The shell only replaces itself with the program given as arguments; no text is ever spliced into this string.
    private static let shellScript = "exec \"$0\" \"$@\""

    let sessionId: String
    let cwd: String
    let resume: Bool
    /// Path of the screen tools server this session is started with; nil - without it.
    let screenTools: String?
    /// The command bar's assistant: its start gets the fixed system prompt text.
    let assistant: Bool
    /// Set for a run started by a routine: the routine's name, shown on the token instead of the project name.
    var routineLabel: String?

    @Published private(set) var items: [ChatItem] = []
    /// Earlier conversation of a continued session, read once from its transcript.
    @Published private(set) var history: [ChatItem] = []
    @Published private(set) var partialText = ""
    @Published private(set) var state: OwnedSessionLogic.State = .starting
    @Published private(set) var lastError: String?
    /// Retry, denial and similar remarks; replaced by the next one, cleared by the next message.
    @Published private(set) var notice: String?
    @Published private(set) var costUSD: Double?
    @Published private(set) var model: String?
    /// Last 4 KB of the child's stderr, shown only when the process fails. Never written anywhere.
    @Published private(set) var stderrTail = ""
    private(set) var turnsFinished = 0
    private(set) var exitedAt: Date?

    /// The CLI reported its session (id, model).
    var onInit: ((String?, String?) -> Void)?
    var onExit: ((Int32) -> Void)?
    /// A turn that was started by voice ended well: the text of its answer, for the spoken reply.
    var onVoiceReply: ((String) -> Void)?
    /// The turn that is running was started by a spoken command.
    private(set) var turnByVoice = false
    /// The message waiting in the command bar's queue for this session was spoken.
    var queuedByVoice = false

    private(set) var logic = OwnedSessionLogic()
    private let config: Config
    private let modelName: String?
    private var process: Process?
    private var pid: pid_t = 0
    private var stdin: FileHandle?
    private let writer = DispatchQueue(label: "agenthud.owned.stdin")
    private var userSeq = 0
    private var generation = 0            // timers of an older request are ignored
    private var silenceTask: Task<Void, Never>?
    private var requestedExit = false
    private var pendingExit: Int32?
    private var stdoutClosed = false

    var isLive: Bool { logic.isLive }
    /// The CLI process (the login shell replaces itself with it); 0 before the start.
    var processId: pid_t { pid }
    var initialized: Bool { logic.initialized }

    init(sessionId: String, cwd: String, resume: Bool, model: String? = nil, screenTools: String? = nil,
         assistant: Bool = false, config: Config = .standard()) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.resume = resume
        self.screenTools = screenTools
        self.assistant = assistant
        self.modelName = model
        self.config = config
    }

    /// Fixed state for the offscreen render check: no process is started.
    init(previewId: String, cwd: String, state: OwnedSessionLogic.State, items: [ChatItem], partialText: String = "",
         lastError: String? = nil, stderrTail: String = "", notice: String? = nil, costUSD: Double? = nil) {
        sessionId = previewId
        self.cwd = cwd
        resume = false
        screenTools = nil
        assistant = false
        modelName = nil
        config = Config(executable: nil, environment: [:])
        self.items = items
        self.partialText = partialText
        self.lastError = lastError
        self.stderrTail = stderrTail
        self.notice = notice
        self.costUSD = costUSD
        switch state {
        case .starting, .exited: break
        default: logic.handle(.initReceived)
        }
        switch state {
        case .starting, .idle: break
        case .running: logic.handle(.userSent)
        case .interrupting: logic.handle(.userSent); logic.handle(.interruptRequested)
        case .handingOver: logic.handle(.stdinClosed)
        case .exited(let code): logic.handle(.processExited(code))
        }
        self.state = logic.state
    }

    // MARK: - Start

    /// Starts the process. On failure the session ends at once with `lastError` set; nothing is thrown.
    func start() {
        guard process == nil, isLive else { return }
        let args = OwnedSessionLogic.arguments(sessionId: sessionId, resume: resume, model: modelName, screenTools: screenTools,
                                                 assistant: assistant)
        guard !args.isEmpty else { return fail("This session id can't be passed to Claude Code") }
        guard let exe = config.executable else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let tried = OwnedSessionLogic.executableCandidates(home: home).map { $0.replacingOccurrences(of: home, with: "~") }
            return fail("Claude Code was not found. Looked in: \(tried.joined(separator: ", "))")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return fail("The project folder does not exist: \(cwd)")
        }

        let p = Process()
        // Through the login shell, so that PATH (node, version managers) is what the person has in a terminal.
        // Everything after the script is passed as separate arguments.
        p.executableURL = URL(fileURLWithPath: Self.loginShell)
        p.arguments = ["-lc", Self.shellScript, exe.path] + args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        p.environment = config.environment
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        // Writing to a child that has gone must fail with an error, not end this app with a signal.
        _ = fcntl(inPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let lines = LineSplitter()
        let parser = ParserBox(cwd: cwd)
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.stdoutEnded() } }
                return
            }
            var events: [StreamEvent] = []
            for line in lines.append(data) { events += parser.feed(line) }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(events) } }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            let text = String(decoding: data.suffix(Self.stderrLimit), as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.appendStderr(text) } }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationReason == .uncaughtSignal ? -proc.terminationStatus : proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.processEnded(code) } }
        }
        do {
            try p.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return fail("Couldn't start Claude Code: \(error.localizedDescription)")
        }
        process = p
        pid = p.processIdentifier
        stdin = inPipe.fileHandleForWriting
        apply(.spawned)
    }

    /// Reads the earlier conversation of a continued session (off the main thread).
    func loadHistory(transcriptPath: String?) {
        guard let path = transcriptPath else { return }
        let url = URL(fileURLWithPath: path)
        Task.detached(priority: .userInitiated) { [weak self] in
            let read = Transcript.read(url, limit: 200, maxBytes: 4_000_000)
            await self?.setHistory(read)
        }
    }

    private func setHistory(_ read: [ChatItem]) { history = read }

    private func fail(_ message: String) {
        lastError = message
        exitedAt = Date()
        apply(.processExited(127))
        onExit?(127)
    }

    // MARK: - Actions

    /// Sends one user turn. False when the session cannot take a message right now.
    @discardableResult
    func send(_ text: String, byVoice: Bool = false) -> Bool {
        guard logic.canSend, let stdin else { return false }
        turnByVoice = byVoice
        let line = StreamParser.userLine(text)
        apply(.userSent)
        userSeq += 1
        StreamParser.merge([ChatItem(id: "sent-\(userSeq)", time: Date(), kind: .user(text))], into: &items)
        notice = nil
        lastError = nil
        // A long message can fill the pipe; the write must not block the main thread.
        writer.async { [weak self] in
            do { try stdin.write(contentsOf: line) } catch {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.lastError = "The message could not be delivered to the session" } }
            }
        }
        watchForSilence()
        return true
    }

    /// Ends the current turn. A second request while the first has not worked ends the process.
    func interrupt() {
        if logic.state == .interrupting { terminate(); return }
        guard logic.canInterrupt else { return }
        apply(.interruptRequested)
        signalChild(SIGINT)
    }

    /// Lets the session leave: stdin is closed, and if the process is still there after the grace time it is terminated.
    func finish() {
        guard isLive, process != nil else { return }
        requestedExit = true
        closeStdin()
        apply(.stdinClosed)
        generation += 1
        let gen = generation, grace = config.finishGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard let self, gen == self.generation, self.isLive else { return }
            self.terminate()
        }
    }

    func terminate() {
        guard isLive, process != nil else { return }
        requestedExit = true
        closeStdin()
        signalChild(SIGTERM)
        generation += 1
        let gen = generation, grace = config.killGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(grace))
            guard let self, gen == self.generation, self.isLive else { return }
            self.signalChild(SIGKILL)
        }
    }

    /// For quitting the app: close stdin of every session, give them a moment, then terminate and kill what is left.
    /// Blocks the caller for at most `wait` + 1 s.
    static func shutDown(_ sessions: [OwnedSession], wait: TimeInterval = 2) {
        let live = sessions.filter { $0.isLive && $0.pid > 0 }
        guard !live.isEmpty else { return }
        for s in live { s.requestedExit = true; s.closeStdin() }
        func alive() -> [OwnedSession] { live.filter { $0.process?.isRunning == true } }
        func pause(_ seconds: TimeInterval, while condition: () -> Bool) {
            let end = Date().addingTimeInterval(seconds)
            while condition(), Date() < end { usleep(50_000) }
        }
        pause(wait) { !alive().isEmpty }
        for s in alive() { s.signalChild(SIGTERM) }
        pause(0.7) { !alive().isEmpty }
        for s in alive() { s.signalChild(SIGKILL) }
    }

    private func closeStdin() {
        guard let h = stdin else { return }
        stdin = nil
        // After pending writes, so that a message sent just before is not cut.
        writer.async { try? h.close() }
    }

    /// The child leads its own process group when the system put it into one; then the signal reaches the tools
    /// it started too. A group this app belongs to is never signalled.
    private func signalChild(_ sig: Int32) {
        guard pid > 0, process?.isRunning == true else { return }
        if getpgid(pid) == pid, pid != getpgrp() { kill(-pid, sig) } else { kill(pid, sig) }
    }

    // MARK: - Output

    private func apply(_ e: OwnedSessionLogic.Event) {
        logic.handle(e)
        if state != logic.state { state = logic.state }
    }

    private func received(_ events: [StreamEvent]) {
        silenceTask?.cancel()
        silenceTask = nil
        for e in events {
            switch e {
            case .initialized(let id, let model):
                apply(.initReceived)
                if let model { self.model = model }
                onInit?(id, model)
            case .items(let updates):
                StreamParser.merge(updates, into: &items)
            case .partialText(let t):
                partialText = t
            case .turnFinished(let success, let cost, let error):
                let interrupted = logic.state == .interrupting
                apply(.turnFinished)
                turnsFinished += 1
                let byVoice = turnByVoice
                turnByVoice = false
                if let cost { costUSD = cost }
                partialText = ""
                settleRunningTools()
                if interrupted {
                    notice = "Interrupted"
                } else if !success {
                    lastError = error.map { "The turn ended with an error: \($0)" } ?? "The turn ended with an error"
                }
                // Only a turn that ended well and was not interrupted has an answer worth reading out.
                if byVoice, success, !interrupted, let reply = VoiceReply.finalText(in: items) { onVoiceReply?(reply) }
            case .notice(let text):
                notice = text
            }
        }
    }

    private func appendStderr(_ text: String) {
        let joined = stderrTail + text
        stderrTail = joined.utf8.count > Self.stderrLimit ? String(decoding: Array(joined.utf8).suffix(Self.stderrLimit), as: UTF8.self) : joined
    }

    /// A tool row that never got its result (the turn or the process ended) must not spin forever.
    private func settleRunningTools() {
        for (i, item) in items.enumerated() {
            if case .tool(let name, let summary, .running) = item.kind {
                items[i] = ChatItem(id: item.id, time: item.time, kind: .tool(name: name, summary: summary, status: .failed))
            }
        }
    }

    private func watchForSilence() {
        silenceTask?.cancel()
        let limit = config.responseTimeout
        silenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard let self, !Task.isCancelled, self.isLive else { return }
            self.notice = "No response from Claude Code for \(Int(limit)) s. It may still be starting; interrupt to give up."
        }
    }

    // MARK: - Exit

    private func stdoutEnded() {
        stdoutClosed = true
        if let code = pendingExit { finishExit(code) }
    }

    private func processEnded(_ code: Int32) {
        guard isLive, pendingExit == nil else { return }
        pendingExit = code
        if stdoutClosed { finishExit(code); return }
        // The last lines may still be in the pipe; a tool left behind by the child could also keep it open forever.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.isLive else { return }
            self.finishExit(code)
        }
    }

    private func finishExit(_ code: Int32) {
        guard isLive else { return }
        generation += 1
        silenceTask?.cancel()
        silenceTask = nil
        stdin = nil
        let before = logic
        apply(.processExited(code))
        exitedAt = Date()
        partialText = ""
        settleRunningTools()
        if !before.initialized, !(requestedExit && code == 0) {
            lastError = "Claude Code exited before the session started (code \(code))"
        } else if !requestedExit {
            lastError = "The session's process exited by itself (code \(code))"
        }
        onExit?(code)
    }
}

/// Cuts the stdout byte stream into lines. Used only from the pipe's read handler, whose calls never overlap.
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private var skipping = false
    /// A single line longer than this is dropped: it cannot be a message worth showing.
    private static let maxLine = 16_000_000

    func append(_ data: Data) -> [Data] {
        var out: [Data] = []
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            if skipping { skipping = false; continue }
            if !line.isEmpty { out.append(line) }
        }
        if buffer.count > Self.maxLine {
            buffer.removeAll()
            skipping = true
        }
        return out
    }
}

private final class ParserBox: @unchecked Sendable {
    private var parser: StreamParser
    init(cwd: String) { parser = StreamParser(cwd: cwd) }
    func feed(_ line: Data) -> [StreamEvent] { parser.feed(line) }
}
