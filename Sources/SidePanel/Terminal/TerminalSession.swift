import AppKit
import Combine
import SidePanelCore

/// One shell: its PTY process, emulator state and view.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    let emulator: TerminalEmulator
    let view: TerminalView

    @Published private(set) var title: String = "shell"
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?
    /// Output arrived while the session wasn't on screen.
    @Published var hasUnseenOutput = false
    @Published private(set) var startError: String?

    var isVisible = false {
        didSet { if isVisible { hasUnseenOutput = false } }
    }

    private var process: PTYProcess?
    private let settings: AppSettings
    private let initialDirectory: String?
    private var shellName = "shell"

    init(settings: AppSettings, workingDirectory: String?) {
        self.settings = settings
        self.initialDirectory = workingDirectory
        self.emulator = TerminalEmulator(columns: 80, rows: 24, scrollbackLimit: max(settings.scrollbackLines, 0))
        self.view = TerminalView(emulator: emulator, fontSize: CGFloat(settings.terminalFontSize))
        view.optionAsMeta = settings.optionAsMeta
        view.cursorBlinkEnabled = settings.cursorBlink

        view.send = { [weak self] bytes in self?.process?.write(bytes) }
        view.onResize = { [weak self] cols, rows in self?.resize(columns: cols, rows: rows) }
        view.onRestartRequest = { [weak self] in self?.restart() }
        view.isProcessRunning = { [weak self] in self?.isRunning ?? false }

        emulator.onResponse = { [weak self] bytes in self?.process?.write(bytes) }
        emulator.onTitleChange = { [weak self] _ in self?.refreshTitle() }
        emulator.onBell = { [weak self] in self?.view.ringBell() }

        start(in: workingDirectory)
    }

    // MARK: Lifecycle

    private func start(in directory: String?) {
        let shell = settings.shellPath.trimmingCharacters(in: .whitespaces)
        let shellPath = (!shell.isEmpty && FileManager.default.isExecutableFile(atPath: shell)) ? shell : PTYProcess.defaultShell()
        shellName = (shellPath as NSString).lastPathComponent
        let cwd = directory.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }

        do {
            let process = try PTYProcess.spawnLoginShell(columns: emulator.columns, rows: emulator.rows,
                                                         workingDirectory: cwd, shell: shellPath)
            process.onOutput = { [weak self] data in self?.receive(data) }
            process.onExit = { [weak self] code in self?.processExited(code) }
            self.process = process
            isRunning = true
            exitCode = nil
            startError = nil
            process.start()
        } catch {
            isRunning = false
            startError = "\(error)"
            emulator.feed("\u{1B}[31m\(error)\u{1B}[0m\r\n")
            view.contentDidChange()
        }
        refreshTitle()
    }

    func restart() {
        guard !isRunning else { return }
        emulator.feed("\u{1B}[0m\u{1B}[2J\u{1B}[H")
        view.contentDidChange()
        start(in: initialDirectory)
    }

    func terminate() {
        process?.onOutput = nil
        process?.onExit = nil
        process?.terminate()
        process = nil
        isRunning = false
    }

    private func receive(_ data: Data) {
        emulator.feed(data)
        view.contentDidChange()
        if !isVisible { hasUnseenOutput = true }
    }

    private func processExited(_ code: Int32) {
        isRunning = false
        exitCode = code
        process = nil
        let message = "\r\n\u{1B}[0m\u{1B}[2m[process exited with code \(code) — press Return to start a new shell]\u{1B}[0m\r\n"
        emulator.feed(message)
        view.contentDidChange()
        refreshTitle()
    }

    private func resize(columns: Int, rows: Int) {
        emulator.resize(columns: columns, rows: rows)
        process?.resize(columns: columns, rows: rows)
        view.contentDidChange()
    }

    // MARK: Actions

    /// ⌘K: wipe the history and ask the shell to redraw its prompt.
    func clear() {
        view.clearScrollback(nil)
        if isRunning && !emulator.isAlternateScreen {
            emulator.feed("\u{1B}[H\u{1B}[2J")
            process?.write([0x0C]) // Ctrl-L: shells redraw the prompt
        }
        view.contentDidChange()
    }

    func apply(settings: AppSettings) {
        view.setFontSize(CGFloat(settings.terminalFontSize))
        view.optionAsMeta = settings.optionAsMeta
        view.cursorBlinkEnabled = settings.cursorBlink
        emulator.scrollbackLimit = max(settings.scrollbackLines, 0)
    }

    // MARK: Title

    var currentDirectory: String? {
        process?.currentDirectory ?? emulator.currentDirectory
    }

    func refreshTitle() {
        let newTitle: String
        if !emulator.title.isEmpty {
            newTitle = emulator.title
        } else if let fg = process?.foregroundProcessName, !fg.isEmpty, fg != shellName, "-" + shellName != fg {
            newTitle = fg
        } else if let dir = currentDirectory {
            let home = PTYProcess.homeDirectory()
            if dir == home { newTitle = "~" }
            else if dir.hasPrefix(home + "/") { newTitle = "~/" + (dir as NSString).lastPathComponent }
            else { newTitle = (dir as NSString).lastPathComponent.isEmpty ? dir : (dir as NSString).lastPathComponent }
        } else {
            newTitle = shellName
        }
        if newTitle != title { title = newTitle }
    }
}

/// The set of terminal sessions shown in the terminal section.
@MainActor
final class TerminalManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedID: UUID? {
        didSet { updateVisibility() }
    }

    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()
    private var titleTimer: Timer?
    private var sessionSubscriptions: [UUID: AnyCancellable] = [:]

    init(settings: AppSettings) {
        self.settings = settings
        Publishers.MergeMany(
            settings.$terminalFontSize.map { _ in () }.eraseToAnyPublisher(),
            settings.$optionAsMeta.map { _ in () }.eraseToAnyPublisher(),
            settings.$cursorBlink.map { _ in () }.eraseToAnyPublisher(),
            settings.$scrollbackLines.map { _ in () }.eraseToAnyPublisher()
        )
        .dropFirst(4)
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.applySettings() }
        .store(in: &cancellables)

        let t = Timer(timeInterval: 1.0, target: self, selector: #selector(refreshTitles), userInfo: nil, repeats: true)
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        titleTimer = t
    }

    var selected: TerminalSession? {
        sessions.first { $0.id == selectedID } ?? sessions.first
    }

    func ensureSession() {
        if sessions.isEmpty { newSession() }
    }

    func newSession() {
        let cwd = selected?.currentDirectory ?? PTYProcess.homeDirectory()
        let session = TerminalSession(settings: settings, workingDirectory: cwd)
        sessionSubscriptions[session.id] = Publishers.Merge3(
            session.$title.removeDuplicates().map { _ in () },
            session.$hasUnseenOutput.removeDuplicates().map { _ in () },
            session.$isRunning.removeDuplicates().map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in self?.objectWillChange.send() }
        if let i = sessions.firstIndex(where: { $0.id == selectedID }) {
            sessions.insert(session, at: i + 1)
        } else {
            sessions.append(session)
        }
        selectedID = session.id
    }

    func close(_ session: TerminalSession) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        session.terminate()
        sessionSubscriptions[session.id] = nil
        session.view.removeFromSuperview()
        sessions.remove(at: i)
        if selectedID == session.id {
            selectedID = sessions.isEmpty ? nil : sessions[min(i, sessions.count - 1)].id
        }
    }

    func closeSelected() {
        if let s = selected { close(s) }
    }

    func select(_ session: TerminalSession) {
        selectedID = session.id
    }

    func cycle(_ delta: Int) {
        guard let i = sessions.firstIndex(where: { $0.id == selected?.id }), !sessions.isEmpty else { return }
        selectedID = sessions[(i + delta + sessions.count) % sessions.count].id
    }

    func select(number: Int) {
        guard !sessions.isEmpty else { return }
        let i = number >= 9 ? sessions.count - 1 : min(number - 1, sessions.count - 1)
        selectedID = sessions[i].id
    }

    func moveSession(_ id: UUID, before target: UUID) {
        guard id != target, let from = sessions.firstIndex(where: { $0.id == id }) else { return }
        let s = sessions.remove(at: from)
        let to = sessions.firstIndex(where: { $0.id == target }) ?? sessions.count
        sessions.insert(s, at: to)
    }

    func focusSelected(in window: NSWindow) {
        guard let view = selected?.view else { return }
        window.makeFirstResponder(view)
    }

    /// Whether Escape should go to the program instead of hiding the panel.
    var wantsEscapeKey: Bool {
        guard let session = selected else { return false }
        guard let window = session.view.window, window.firstResponder === session.view else { return false }
        if session.emulator.isAlternateScreen { return true }
        return !settings.terminalEscapeHides
    }

    func zoom(_ direction: Int) {
        switch direction {
        case 0: settings.terminalFontSize = 12.5
        case let d where d > 0: settings.terminalFontSize = min(settings.terminalFontSize + 1, 28)
        default: settings.terminalFontSize = max(settings.terminalFontSize - 1, 8)
        }
    }

    func terminateAll() {
        sessions.forEach { $0.terminate() }
    }

    private func applySettings() {
        sessions.forEach { $0.apply(settings: settings) }
    }

    private func updateVisibility() {
        for s in sessions { s.isVisible = (s.id == selected?.id) }
    }

    @objc private func refreshTitles() {
        sessions.forEach { $0.refreshTitle() }
    }
}
