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
    /// The kept summaries, newest first.
    public var notes: @Sendable () -> [SessionNote] = { [] }
    public var deleteNote: @Sendable (String) -> Bool = { _ in false }
    /// Whether Claude Code still has the conversation with this id.
    public var conversationExists: @Sendable (String) -> Bool = { _ in false }

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
        var services = PaletteServices(
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
        services.notes = { NotesArchive().all() }
        services.deleteNote = { (try? NotesArchive().delete($0)) != nil }
        services.conversationExists = { ConversationReader().file(for: $0) != nil }
        return services
    }
}

/// The launcher palette: pick a folder, write a prompt, start a session.
@MainActor
@Observable
public final class PaletteModel {
    public enum Step: Equatable {
        case folder
        /// The kept summaries, instead of sessions and repositories. Tab goes there and back.
        case notes
        /// Writing a reply to the session that was selected.
        case reply
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
    /// Pins or unpins a session.
    public var onTogglePin: (String) -> Void = { _ in }
    /// Stops or removes a session, once the user has confirmed it here.
    public var onControl: (PendingControl) async -> ControlOutcome = { _ in .couldNotRun("Not available") }

    /// A stop or removal waiting for Return, and what the last one came to.
    public private(set) var pendingControl: PendingControl?
    /// Sends a choice to its session and returns what to tell the user.
    public var onAnswer: (InboxModel.PendingAnswer) -> String = { _ in "Not available" }
    /// An option chosen for the selected session's question, waiting for Return.
    public private(set) var pendingAnswer: InboxModel.PendingAnswer?
    private var answered: Set<String> = []
    public private(set) var controlMessage: String?
    /// The last removal Claude Code refused, kept while its row stays selected.
    public private(set) var refusedRemoval: ControlProblem?
    /// Opens Claude Code in a folder so the user can accept its trust prompt.
    public var onTrust: (String) -> Void = { _ in }
    public var onCopy: (String) -> Void = { _ in }
    public var onClose: () -> Void = {}

    public init(services: PaletteServices) {
        self.services = services
    }

    // MARK: Notes

    public static let visibleNotes = 5

    /// Every kept summary, as last read.
    public private(set) var notes: [SessionNote] = []
    /// The ones matching what is typed; all of them, newest first, when nothing is.
    public private(set) var noteResults: [SessionNote] = []
    public private(set) var noteSelection = 0
    /// The note whose deletion waits for Return.
    public private(set) var pendingNoteDeletion: SessionNote?
    public private(set) var noteMessage: String?
    /// True when the palette was opened on its notes, so Escape closes it instead of going back.
    private var openedOnNotes = false
    /// Resumes a removed session's conversation in the terminal.
    public var onResume: (SessionNote) -> Void = { _ in }

    /// The clock the notes' ages are measured against.
    public var now: Date { services.now() }

    public var selectedNote: SessionNote? {
        noteResults.indices.contains(noteSelection) ? noteResults[noteSelection] : nil
    }

    public var visibleNoteResults: ArraySlice<SessionNote> {
        let first = max(0, min(noteSelection - Self.visibleNotes + 1, noteResults.count - Self.visibleNotes))
        return noteResults[first..<min(first + Self.visibleNotes, noteResults.count)]
    }

    /// For the ordinary list's last line: how many notes there are to switch to. With text, the
    /// ones that match it; a path is never a search for notes.
    public var notesOnOffer: Int {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.hasPrefix("/"), !text.hasPrefix("~") else { return 0 }
        return NotesArchive.matching(notes, text).count
    }

    public func reach(of note: SessionNote) -> NoteReach {
        NoteReach.of(note, liveSessionIDs: Set(sessions.map(\.id)), conversationExists: services.conversationExists, folderExists: services.isFolder)
    }

    private func rankNotes() {
        noteResults = NotesArchive.matching(notes, query)
        noteSelection = min(noteSelection, max(noteResults.count - 1, 0))
    }

    /// Tab: from the list to the notes and back, with what was typed.
    public func toggleNotes() {
        switch step {
        case .folder:
            step = .notes
            pendingControl = nil
            pendingAnswer = nil
            pendingNoteDeletion = nil
            noteMessage = nil
            noteSelection = 0
            notes = services.notes()
            rankNotes()
        case .notes:
            step = .folder
            pendingNoteDeletion = nil
            selection = 0
            rank()
        default:
            return
        }
        focusRequest += 1
    }

    /// Opens the palette on its notes, for the link in the Triage tab.
    public func beginOnNotes() async {
        await begin()
        toggleNotes()
        openedOnNotes = true
    }

    public func moveNoteSelection(by offset: Int) {
        guard !noteResults.isEmpty else { return }
        pendingNoteDeletion = nil
        noteMessage = nil
        noteSelection = max(0, min(noteResults.count - 1, noteSelection + offset))
    }

    public func select(_ note: SessionNote) {
        if let position = noteResults.firstIndex(of: note) {
            noteSelection = position
            pendingNoteDeletion = nil
        }
    }

    /// What Return will do with the selected note, for the hint.
    public var noteVerb: String {
        guard let note = selectedNote else { return "Open" }
        switch reach(of: note) {
        case .session: return "Open the session"
        case .conversation: return "Resume in terminal"
        case .summaryOnly: return "Copy summary"
        }
    }

    /// Return on a note: the most that can still be done with it.
    public func confirmNote() {
        guard step == .notes else { return }
        if let pending = pendingNoteDeletion {
            pendingNoteDeletion = nil
            if services.deleteNote(pending.id) {
                notes.removeAll { $0.id == pending.id }
                rankNotes()
                noteMessage = "Deleted the note about \(pending.name)."
            } else {
                noteMessage = "The note could not be deleted."
            }
            return
        }
        guard let note = selectedNote else { return }
        switch reach(of: note) {
        case .session:
            onOpenSession(note.id)
            onClose()
        case .conversation:
            onResume(note)
            onClose()
        case .summaryOnly:
            copySelectedNote()
        }
    }

    /// ⌘Return: the summary on the clipboard, with where it was from.
    public func copySelectedNote() {
        guard step == .notes, let note = selectedNote else { return }
        var heading = "\(note.name) (\(note.repo)"
        if let branch = note.branch { heading += ", \(branch)" }
        onCopy("\(heading))\n\(note.summary)")
        noteMessage = "Summary copied."
    }

    /// ⌘D: asks to delete the selected note. Return then does it.
    public func askDeleteSelectedNote() {
        guard step == .notes, let note = selectedNote else { return }
        noteMessage = nil
        pendingNoteDeletion = note
    }

    // MARK: Opening

    /// Starts over with an empty palette and reads the repositories again. What was loaded last
    /// time stays on screen until the new list arrives.
    public func begin() async {
        step = .folder
        openedOnNotes = false
        pendingNoteDeletion = nil
        noteMessage = nil
        pendingControl = nil
        pendingAnswer = nil
        showsWholeSaid = false
        replyRow = nil
        replyText = ""
        replyMessage = nil
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
        notes = services.notes()
        rank()
        await reload()
    }

    /// The sessions were read again while the palette is open: its list follows, so a session
    /// that was just answered or replied to stops showing as waiting. The selection stays on the
    /// same thing when that is still listed; a choice not yet sent stays with it.
    public func sessionsChanged() async {
        guard step == .folder else { return }
        let fresh = await services.sessions()
        guard fresh != sessions else { return }
        let selected = selectedItem?.id
        sessions = fresh
        rank()
        if let selected, let position = items.firstIndex(where: { $0.id == selected }) {
            selection = position
        } else {
            // What was selected is gone from the list: nothing about it is left pending.
            pendingControl = nil
            pendingAnswer = nil
            showsWholeSaid = false
        }
        if let pending = pendingAnswer, selectedSession?.answerID != pending.questionID { pendingAnswer = nil }
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
        pendingAnswer = nil
        showsWholeSaid = false
        pendingNoteDeletion = nil
        noteMessage = nil
        query = text
        selection = 0
        noteSelection = 0
        rank()
        rankNotes()
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
    /// How many finished sessions are listed before anything is typed: the latest ones, which
    /// are the ones a follow-up is likely for. The rest are found by typing.
    public static let doneSessionsShown = 3

    static func sessions(_ sessions: [InboxRow], matching query: String) -> [InboxRow] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            // The ones the user keeps come first, whatever they are doing; then the rest as before.
            let pinned = sessions.filter(\.isPinned)
            let others = sessions.filter { !$0.isPinned }
            let waiting = others.filter { $0.kind.needsUser }
            let working = others.filter { $0.kind == .working }.prefix(workingSessionsShown)
            let done = others.filter { $0.kind == .done }.prefix(doneSessionsShown)
            return pinned + waiting + working + done
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
        pendingAnswer = nil
        showsWholeSaid = false
        refusedRemoval = nil
        selection = max(0, min(count - 1, selection + offset))
    }

    public func select(_ item: Item) {
        guard let position = items.firstIndex(of: item) else { return }
        if position != selection {
            pendingAnswer = nil
            showsWholeSaid = false
        }
        selection = position
    }

    /// Return on the first step: open the selected session, or go on to the prompt for the
    /// selected folder.
    public func confirmFolder() {
        guard step == .folder else { return }
        if pendingControl != nil {
            Task { await confirmControl() }
            return
        }
        if pendingAnswer != nil {
            Task { await sendAnswer() }
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
        // Asked again for a removal Claude Code refused, with what it said could be discarded:
        // the second question, with its refusal in full.
        if action == .remove, let refused = refusedRemoval, refused.sessionID == row.id, !refused.overrides.isEmpty {
            pendingControl = PendingControl(sessionID: row.id, name: row.title, action: .remove, overrides: refused.overrides, refusal: refused.text)
            return
        }
        controlMessage = nil
        refusedRemoval = nil
        pendingAnswer = nil
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
        if case .refused(let text) = outcome {
            let problem = ControlProblem(sessionID: pending.sessionID, name: pending.name, action: pending.action, text: text)
            refusedRemoval = problem.overrides.isEmpty ? nil : problem
            if refusedRemoval != nil { controlMessage = text + "\n\nPress ⌘D again to discard that and remove it anyway." }
        } else {
            refusedRemoval = nil
        }
        sessions = await services.sessions()
        rank()
    }

    // MARK: Replying to a session

    /// Sends a reply to a session for one turn's end; says whether it went and what to tell the user.
    public var onReply: (_ sessionID: String, _ turnID: String, _ text: String) async -> (sent: Bool, message: String) = { _, _, _ in (false, "Not available") }
    /// The session being replied to, as it was when the reply was begun.
    public private(set) var replyRow: InboxRow?
    public private(set) var replyText = ""
    /// Why the reply did not go, when it did not.
    public private(set) var replyMessage: String?
    public private(set) var isSendingReply = false

    /// ⌘Return on a session that can take a reply: a field to write it in. On one that cannot,
    /// what ⌘Return always did: its suggested reply copied and the session opened.
    public func replyOrCopySelected() {
        guard step == .folder, let row = selectedSession else { return }
        guard row.reply != nil else { return copyReplyAndOpenSelected() }
        replyRow = row
        replyText = ""
        replyMessage = nil
        pendingControl = nil
        pendingAnswer = nil
        step = .reply
        focusRequest += 1
    }

    public func setReplyText(_ text: String) {
        replyText = text
        replyMessage = nil
    }

    /// Puts the reply Claude Code suggests in the field. Only into an empty one.
    public func useSuggestedReply() {
        guard step == .reply, let suggested = replyRow?.suggestedReply, replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        replyText = suggested
        focusRequest += 1
    }

    public var canSendReply: Bool {
        step == .reply && !isSendingReply && !replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// ⌘Return in the field: sends what is written. Sent, the palette goes back to its list and
    /// says so; not sent, it stays on the reply with the reason, and the text is kept.
    public func sendReply() async {
        guard canSendReply, let row = replyRow, let target = row.reply else { return }
        isSendingReply = true
        let outcome = await onReply(row.id, target.turnID, replyText)
        isSendingReply = false
        guard outcome.sent else {
            replyMessage = outcome.message
            return
        }
        replyRow = nil
        replyText = ""
        step = .folder
        controlMessage = outcome.message
        focusRequest += 1
        sessions = await services.sessions()
        rank()
    }

    /// Back to the list without sending. What was written is dropped.
    public func cancelReply() {
        guard step == .reply else { return }
        replyRow = nil
        replyText = ""
        replyMessage = nil
        step = .folder
        focusRequest += 1
    }

    // MARK: What the selected session said

    /// Whether the selected session's last words are shown whole rather than only their ending.
    /// It is about the row that is selected: moving on, typing or closing puts it back.
    public private(set) var showsWholeSaid = false

    /// Whether there is more of it than the row shows.
    public var canShowMoreSaid: Bool {
        guard step == .folder, let row = selectedSession, let said = row.said else { return false }
        return said != row.saidEnding
    }

    /// ⌘E, or a click on the line under the text.
    public func toggleWholeSaid() {
        guard canShowMoreSaid else { return }
        showsWholeSaid.toggle()
    }

    // MARK: Answering a question

    /// Whether the selected row's question can be answered from here: it takes an answer, and
    /// one was not already sent for this asking.
    public func canAnswer(_ row: InboxRow) -> Bool {
        row.answerID.map { !answered.contains($0) } ?? false
    }

    /// The option chosen for this row, if the choice is for the question it shows now.
    public func chosenOption(for row: InboxRow) -> Int? {
        guard let pending = pendingAnswer, pending.sessionID == row.id, pending.questionID == row.answerID else { return nil }
        return pending.option
    }

    /// ⌘1 to ⌘9, or a click: chooses an option of the selected session's question. Nothing is
    /// sent; Return then sends it, Escape or moving on does not.
    public func chooseAnswer(_ option: Int) {
        guard step == .folder, let row = selectedSession, canAnswer(row), let id = row.answerID, row.options.indices.contains(option) else { return }
        pendingControl = nil
        controlMessage = nil
        pendingAnswer = InboxModel.PendingAnswer(sessionID: row.id, option: option, questionID: id)
    }

    /// Sends the chosen option. The palette stays open, saying what came of it.
    public func sendAnswer() async {
        guard let pending = pendingAnswer else { return }
        pendingAnswer = nil
        controlMessage = onAnswer(pending)
        // The list may be read again before the session is seen to move on: its options are
        // not offered a second time for the same asking.
        answered.insert(pending.questionID)
        sessions = await services.sessions()
        rank()
    }

    /// Pins the selected session, or unpins it. The palette stays open on the same session.
    public func togglePinSelected() async {
        guard step == .folder, let row = selectedSession else { return }
        pendingControl = nil
        onTogglePin(row.id)
        sessions = await services.sessions()
        rank()
        if let position = items.firstIndex(where: { $0.id == "session:\(row.id)" }) { selection = position }
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
            } else if pendingAnswer != nil {
                pendingAnswer = nil
            } else {
                onClose()
            }
        case .notes:
            if pendingNoteDeletion != nil {
                pendingNoteDeletion = nil
            } else if openedOnNotes {
                onClose()
            } else {
                toggleNotes()
            }
        case .prompt: back()
        case .reply: cancelReply()
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
