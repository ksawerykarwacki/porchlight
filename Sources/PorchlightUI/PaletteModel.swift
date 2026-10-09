import Foundation
import Observation
import PorchlightCore

/// What the palette needs from outside itself. Closures, so tests can stand in for the disk and
/// for `claude`.
public struct PaletteServices: Sendable {
    public var loadIndex: @Sendable () async -> RepoIndex
    /// The sessions as the inbox shows them, in the inbox's order.
    public var sessions: @Sendable () async -> [InboxRow]
    public var loadHistory: @Sendable () -> DispatchHistory
    public var saveHistory: @Sendable (DispatchHistory) -> Void
    public var naming: @Sendable () -> NamingSettings
    public var capabilities: @Sendable () async -> DispatchCapabilities
    public var dispatch: @Sendable (DispatchRequest, DispatchCapabilities) async throws -> Dispatched
    public var branch: @Sendable (String) -> String?
    public var isFolder: @Sendable (String) -> Bool
    /// Changes where repositories are looked for, and saves it.
    public var updateRepos: @Sendable (@Sendable (inout RepoIndexSettings) -> Void) -> Void
    public var now: @Sendable () -> Date
    public var home: String

    public init(
        loadIndex: @escaping @Sendable () async -> RepoIndex,
        sessions: @escaping @Sendable () async -> [InboxRow] = { [] },
        loadHistory: @escaping @Sendable () -> DispatchHistory = { DispatchHistory() },
        saveHistory: @escaping @Sendable (DispatchHistory) -> Void = { _ in },
        naming: @escaping @Sendable () -> NamingSettings = { NamingSettings() },
        capabilities: @escaping @Sendable () async -> DispatchCapabilities,
        dispatch: @escaping @Sendable (DispatchRequest, DispatchCapabilities) async throws -> Dispatched,
        branch: @escaping @Sendable (String) -> String? = { _ in nil },
        isFolder: @escaping @Sendable (String) -> Bool = RepoIndex.directoryExists,
        updateRepos: @escaping @Sendable (@Sendable (inout RepoIndexSettings) -> Void) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() },
        home: String = NSHomeDirectory()
    ) {
        self.loadIndex = loadIndex
        self.sessions = sessions
        self.loadHistory = loadHistory
        self.saveHistory = saveHistory
        self.naming = naming
        self.capabilities = capabilities
        self.dispatch = dispatch
        self.branch = branch
        self.isFolder = isFolder
        self.updateRepos = updateRepos
        self.now = now
        self.home = home
    }

    /// The real thing: the settings and history files, the disk, and the installed `claude`.
    public static func live(
        settingsURL: URL = Settings.fileURL(),
        historyURL: URL = DispatchHistory.fileURL(),
        locator: @escaping @Sendable () -> ClaudeLocator,
        sessionDirectories: @escaping @Sendable () async -> [String],
        sessions: @escaping @Sendable () async -> [InboxRow] = { [] }
    ) -> PaletteServices {
        PaletteServices(
            loadIndex: {
                let settings = Settings.load(from: settingsURL).repos ?? RepoIndexSettings()
                let directories = await sessionDirectories()
                return RepoIndex.build(settings: settings, sessionDirectories: directories)
            },
            sessions: sessions,
            loadHistory: { DispatchHistory.load(from: historyURL) },
            saveHistory: { try? $0.save(to: historyURL) },
            naming: { Settings.load(from: settingsURL).naming ?? NamingSettings() },
            capabilities: {
                guard let claude = locator().locate() else { return DispatchCapabilities() }
                return await Dispatcher(claude: claude).capabilities()
            },
            dispatch: { request, capabilities in
                guard let claude = locator().locate() else { throw DispatchError.couldNotRun("the claude command was not found") }
                return try await Dispatcher(claude: claude).dispatch(request, capabilities: capabilities)
            },
            branch: { GitBranch.current(in: $0) },
            updateRepos: { change in
                var settings = Settings.load(from: settingsURL)
                var repos = settings.repos ?? RepoIndexSettings()
                change(&repos)
                settings.repos = repos
                try? settings.save(to: settingsURL)
            }
        )
    }
}

/// The launcher palette: pick a folder, write a prompt, start a session.
@MainActor
@Observable
public final class PaletteModel {
    public enum Step: Equatable {
        case folder
        case prompt
        case starting
        case started(Dispatched)
        /// `command` is what was run, to copy; `untrustedFolder` is set when Claude Code has not
        /// been used in the folder yet.
        case failed(message: String, command: String?, untrustedFolder: String?)
    }

    /// The optional settings of a session, collapsed until asked for.
    public struct Options: Equatable, Sendable {
        public var model = ""
        public var effort: String?
        public var agent = ""
        public var permissionMode: String?
        public var usesWorktree = false
        public var worktreeName = ""

        public init() {}
    }

    public static let visibleRows = 8

    private let services: PaletteServices

    public private(set) var step: Step = .folder
    /// Bumped whenever the palette wants the keyboard in its main field again.
    public private(set) var focusRequest = 0
    public private(set) var index = RepoIndex(repos: [])
    public private(set) var history = DispatchHistory()
    public private(set) var capabilities = DispatchCapabilities()
    /// True until the first list of repositories has arrived.
    public private(set) var isLoading = true

    public private(set) var query = ""
    /// The repositories that match, best first.
    public private(set) var results: [Repo] = []
    /// Every session, as last read.
    public private(set) var sessions: [InboxRow] = []
    /// The sessions on offer: with nothing typed the ones that need the user and a few that are
    /// working; with text, every session that matches.
    public private(set) var sessionResults: [InboxRow] = []
    public private(set) var selection = 0

    public private(set) var folder: Repo?
    public private(set) var branch: String?
    public private(set) var prompt = ""
    /// The name as the user changed it; nil while the template's name is used.
    public private(set) var editedName: String?
    public var options = Options()
    public var showsOptions = false

    /// Called when a session was started; the flag says whether to open it as well.
    public var onStarted: (Dispatched, Bool) -> Void = { _, _ in }
    public var onOpen: (Dispatched) -> Void = { _ in }
    /// Opens an existing session in the terminal.
    public var onOpenSession: (String) -> Void = { _ in }
    /// Puts a session's suggested reply on the clipboard.
    public var onCopyReply: (String) -> Void = { _ in }
    public var onSnooze: (String, SnoozeChoice) async -> Void = { _, _ in }
    public var onRetry: (String) -> Void = { _ in }
    /// Stops or removes a session, once the user has confirmed it here.
    public var onControl: (PendingControl) async -> ControlOutcome = { _ in .couldNotRun("Not available") }

    /// A stop or removal waiting for Return, and what the last one came to.
    public private(set) var pendingControl: PendingControl?
    public private(set) var controlMessage: String?
    /// Opens Claude Code in a folder so the user can accept its trust prompt.
    public var onTrust: (String) -> Void = { _ in }
    public var onCopy: (String) -> Void = { _ in }
    public var onClose: () -> Void = {}

    public init(services: PaletteServices) {
        self.services = services
    }

    // MARK: Opening

    /// Starts over with an empty palette and reads the repositories again. What was loaded last
    /// time stays on screen until the new list arrives.
    public func begin() async {
        step = .folder
        pendingControl = nil
        controlMessage = nil
        query = ""
        selection = 0
        folder = nil
        branch = nil
        prompt = ""
        editedName = nil
        options = Options()
        showsOptions = false
        focusRequest += 1
        history = services.loadHistory()
        rank()
        await reload()
    }

    private func reload() async {
        // The sessions come from memory, so they are on screen before the disk has been searched.
        sessions = await services.sessions()
        rank()
        async let loadedIndex = services.loadIndex()
        async let loadedCapabilities = services.capabilities()
        index = await loadedIndex
        capabilities = await loadedCapabilities
        isLoading = false
        rank()
    }

    // MARK: Picking a folder

    public func setQuery(_ text: String) {
        guard text != query else { return }
        pendingControl = nil
        query = text
        selection = 0
        rank()
    }

    /// The folder the text names, when it is a path to one rather than something to search for.
    private var typedFolder: Repo? {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("/") || text.hasPrefix("~") else { return nil }
        let path = RepoPath.normalized(text, home: services.home)
        guard services.isFolder(path) else { return nil }
        return index.repos.first { $0.path == path } ?? Repo(path: path, isIndexed: false)
    }

    private func rank() {
        if let typedFolder {
            results = [typedFolder]
        } else {
            let ranking = RepoRanking(history: history, now: services.now(), home: services.home)
            results = ranking.ranked(index, query: query)
        }
        sessionResults = Self.sessions(sessions, matching: query)
        selection = min(selection, max(items.count - 1, 0))
    }

    /// How many working sessions are listed before anything is typed. The ones that need the
    /// user are all listed.
    public static let workingSessionsShown = 3

    static func sessions(_ sessions: [InboxRow], matching query: String) -> [InboxRow] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            let waiting = sessions.filter { $0.kind.needsUser }
            let working = sessions.filter { $0.kind == .working }.prefix(workingSessionsShown)
            return waiting + working
        }
        // A path is a folder to start in, never a session.
        guard !query.hasPrefix("/"), !query.hasPrefix("~") else { return [] }
        let scored: [(row: InboxRow, score: Int, position: Int)] = sessions.enumerated().compactMap { position, row in
            FuzzyMatch.score(query, name: row.title, path: row.place).map { (row, $0, position) }
        }
        // Equal matches keep the inbox's order, which puts what needs the user first.
        return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.position < $1.position }.map(\.row)
    }

    /// One line of the list: a session to open, or a folder to start a new one in.
    public enum Item: Equatable, Identifiable {
        case session(InboxRow)
        case repo(Repo)

        public var id: String {
            switch self {
            case .session(let row): "session:\(row.id)"
            case .repo(let repo): "repo:\(repo.path)"
            }
        }
    }

    /// Sessions first, then repositories.
    public var items: [Item] {
        sessionResults.map(Item.session) + results.map(Item.repo)
    }

    /// The rows on screen: a window of the list that always holds the selected one.
    public var visibleItems: ArraySlice<Item> {
        let items = items
        let first = max(0, min(selection - Self.visibleRows + 1, items.count - Self.visibleRows))
        return items[first..<min(first + Self.visibleRows, items.count)]
    }

    public var selectedItem: Item? {
        let items = items
        return items.indices.contains(selection) ? items[selection] : nil
    }

    public var selectedRepo: Repo? {
        if case .repo(let repo) = selectedItem { return repo }
        return nil
    }

    public var selectedSession: InboxRow? {
        if case .session(let row) = selectedItem { return row }
        return nil
    }

    public func moveSelection(by offset: Int) {
        let count = items.count
        guard count > 0 else { return }
        // The question was about the row that was selected.
        pendingControl = nil
        selection = max(0, min(count - 1, selection + offset))
    }

    public func select(_ item: Item) {
        if let position = items.firstIndex(of: item) { selection = position }
    }

    /// Return on the first step: open the selected session, or go on to the prompt for the
    /// selected folder.
    public func confirmFolder() {
        guard step == .folder else { return }
        if pendingControl != nil {
            Task { await confirmControl() }
            return
        }
        switch selectedItem {
        case .session(let row): open(row)
        case .repo(let repo): choose(repo)
        case nil: break
        }
    }

    // MARK: Sessions

    public func open(_ row: InboxRow) {
        onOpenSession(row.id)
        onClose()
    }

    /// The reply the selected session suggests goes on the clipboard and the session opens, so
    /// that pasting it is the next keystroke.
    public func copyReplyAndOpenSelected() {
        guard step == .folder, let row = selectedSession, row.suggestedReply != nil else { return }
        onCopyReply(row.id)
        open(row)
    }

    /// Pauses reminders for the selected session for an hour, or turns them back on if they are
    /// paused. The palette stays open, on the next thing in the list.
    public func snoozeSelected() async {
        guard step == .folder, let row = selectedSession, row.kind.needsUser else { return }
        await onSnooze(row.id, row.isSnoozed ? .wake : .hour)
        sessions = await services.sessions()
        rank()
    }

    /// Asks to stop or remove the selected session. Return then does it; Escape or moving on
    /// does not.
    public func askControlSelected(_ action: SessionAction) {
        guard step == .folder, let row = selectedSession, action == .stop ? row.canStop : row.canRemove else { return }
        controlMessage = nil
        pendingControl = PendingControl(sessionID: row.id, name: row.title, action: action)
    }

    public func cancelControl() {
        pendingControl = nil
    }

    public func confirmControl() async {
        guard let pending = pendingControl else { return }
        pendingControl = nil
        let outcome = await onControl(pending)
        // A refusal is shown in the CLI's own words.
        controlMessage = outcome.succeeded ? pending.action.done(name: pending.name) : outcome.message
        sessions = await services.sessions()
        rank()
    }

    public func retrySelected() {
        guard step == .folder, let row = selectedSession, row.isRetryable else { return }
        onRetry(row.id)
        onClose()
    }

    public func choose(_ repo: Repo) {
        folder = repo
        branch = services.branch(repo.path)
        step = .prompt
        focusRequest += 1
    }

    /// A folder from the open panel or anywhere else, in the list or not.
    public func chooseFolder(path: String) {
        let path = RepoPath.normalized(path, home: services.home)
        guard services.isFolder(path) else { return }
        choose(index.repos.first { $0.path == path } ?? Repo(path: path, isIndexed: false))
    }

    /// The folder and model of the session started last, when that folder is still there.
    public var canRepeatLast: Bool {
        history.last.map { services.isFolder($0.directory) } ?? false
    }

    public func repeatLast() {
        guard step == .folder, let last = history.last, services.isFolder(last.directory) else { return }
        chooseFolder(path: last.directory)
        if let model = last.model, !model.isEmpty {
            options.model = model
            showsOptions = true
        }
    }

    public func togglePin(_ repo: Repo) {
        let pin = !repo.isPinned
        let path = repo.path
        let home = services.home
        services.updateRepos { $0.setPinned(path, pin, home: home) }
        Task { await reload() }
    }

    /// Adds a folder to search for repositories, and searches it.
    public func addRoot(path: String) {
        let path = RepoPath.normalized(path, home: services.home)
        guard services.isFolder(path) else { return }
        let home = services.home
        services.updateRepos { $0.addRoot(path, home: home) }
        Task { await reload() }
    }

    // MARK: Writing the prompt

    public func setPrompt(_ text: String) {
        prompt = text
    }

    /// The name the template gives the prompt as it stands.
    public var templateName: String {
        guard let folder else { return "" }
        return NameTemplate(settings: services.naming()).name(prompt: prompt, directory: folder.path, branch: branch, now: services.now())
    }

    /// The name the session will get: the user's when they changed it, else the template's.
    public var name: String { editedName ?? templateName }

    /// Typing in the name field. Emptying it goes back to the template's name.
    public func setName(_ text: String) {
        editedName = text.trimmingCharacters(in: .whitespaces).isEmpty || text == templateName ? nil : text
    }

    public var canStart: Bool {
        step == .prompt && folder != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Back from the prompt to the folder list, keeping what was typed there.
    public func back() {
        guard step == .prompt else { return }
        step = .folder
        focusRequest += 1
    }

    // MARK: Starting

    var request: DispatchRequest? {
        guard let folder else { return nil }
        let name = name.trimmingCharacters(in: .whitespaces)
        return DispatchRequest(
            directory: folder.path, prompt: prompt, name: name.isEmpty ? nil : name,
            model: options.model, effort: options.effort, agent: options.agent, permissionMode: options.permissionMode,
            worktree: options.usesWorktree ? .named(options.worktreeName) : nil)
    }

    /// Starts the session. `open` also opens it in the terminal.
    public func start(open: Bool) async {
        guard canStart, let request else { return }
        step = .starting
        do {
            let started = try await services.dispatch(request, capabilities)
            history = services.loadHistory()
            history.record(.init(directory: started.directory, name: started.name, model: request.model.flatMap { $0.isEmpty ? nil : $0 }, date: services.now()))
            services.saveHistory(history)
            step = .started(started)
            onStarted(started, open)
            // Opened in the terminal: the palette has nothing more to show.
            if open { onClose() }
        } catch let error as DispatchError {
            step = .failed(message: error.message, command: error.command, untrustedFolder: error.isUntrustedFolder ? (error.untrustedFolder ?? request.directory) : nil)
        } catch {
            step = .failed(message: "Could not start the session: \(error.localizedDescription)", command: nil, untrustedFolder: nil)
        }
    }

    /// From a failure back to the prompt, with everything still filled in.
    public func editAgain() {
        guard case .failed = step else { return }
        step = .prompt
        focusRequest += 1
    }

    public func openStarted() {
        guard case .started(let started) = step else { return }
        onOpen(started)
        onClose()
    }

    public func copyFailedCommand() {
        if case .failed(_, let command?, _) = step { onCopy(command) }
    }

    public func trustFolder() {
        if case .failed(_, _, let folder?) = step { onTrust(folder) }
    }

    /// Escape: one step back, and out of the palette from its first step.
    public func escape() {
        switch step {
        case .folder:
            if pendingControl != nil {
                pendingControl = nil
            } else {
                onClose()
            }
        case .prompt: back()
        case .starting: break
        case .started: onClose()
        case .failed: editAgain()
        }
    }

    /// Return when no text field has the keyboard.
    public func confirm() {
        switch step {
        case .started: onClose()
        case .failed: editAgain()
        default: break
        }
    }
}

extension InboxRow.Kind {
    /// Whether the session is stopped until the user does something.
    var needsUser: Bool { self == .question || self == .approval || self == .waiting }
}
