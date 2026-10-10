import AppKit
import Foundation
import Observation
import PorchlightCore
import PorchlightMac

/// Mirrors the session store onto the main actor and carries out what the inbox's buttons do.
@MainActor
@Observable
public final class InboxModel {
    private let store: SessionStore
    /// Set only by tests; otherwise a launcher is made for the chosen terminal on each open.
    private let injectedLauncher: (any TerminalLauncher)?
    private let locator: ClaudeLocator
    private nonisolated let injectedLocator: ClaudeLocator?
    private let clock: @Sendable () -> Date
    private nonisolated let settingsURL: URL
    private let engine: ReminderEngine
    private var delivery: UserNotificationDelivery?
    private var log: ActivityLog?
    /// Why reminders are not reaching the screen, or nil when they can.
    public private(set) var notificationProblem: String?

    /// The terminal the user picked, or nil for "whichever is running".
    public private(set) var chosenTerminal: TerminalApp?
    public let installedTerminals: [TerminalApp]
    /// Switch to an agent view that is already open instead of attaching in a new tab.
    public private(set) var prefersAgentView = false
    /// The shortcut that opens the new-session palette from any app.
    public private(set) var hotkey: Hotkey?
    /// Registers a shortcut with the system, or removes it for nil. Returns false when the
    /// system refused it. Set by the app; the model only decides and remembers.
    public var registerHotkey: (Hotkey?) -> Bool = { _ in true }

    public private(set) var snapshot = StoreSnapshot()
    /// When and how to remind, as last saved.
    public private(set) var reminderSettings = ReminderSettings()
    /// Which waiting text counts as a passing failure. Read from the settings when the app starts.
    public private(set) var transientErrors = TransientErrors()
    /// Whether the panel shows the reminder settings instead of the sessions.
    public var showsSettings = false
    /// Whether the panel shows the Triage tab instead of the sessions.
    public var showsTriage = false
    /// Which row or button the pointer is over.
    public let hover = HoverTracker()
    /// The result of the last action, shown briefly at the bottom of the inbox.
    public private(set) var notice: String?
    /// What Porchlight can see of its own set-up, and the steps that follow from it.
    public private(set) var setupFacts = SetupFacts()
    public var setupSteps: [SetupStep] { Setup.steps(for: setupFacts) }
    private let loginItem: LoginItem
    /// Asks the user for a folder; returns its path or nil. Set by the app.
    public var pickFolder: () -> String? = { nil }
    /// Opens the system's notification settings. Set by the app.
    public var openNotificationSettings: () -> Void = {}
    /// Reads `claude --version`. Replaceable in tests.
    var readClaudeVersion: @Sendable (URL) async -> CLIVersion? = { claude in
        guard let result = try? await CLIRunner().run(claude, ["--version"], timeout: 10), result.succeeded else { return nil }
        return CLIVersion(parsing: result.stdout)
    }

    /// The sessions the user keeps on purpose.
    public private(set) var pins = Pins()
    private let pinsURL: URL
    /// Shows the list of sessions after a click on the daily summary. Set by the app: the
    /// menu-bar panel cannot be opened from code, the palette can.
    public var showInbox: () -> Void = {}

    /// A stop or removal waiting for the user to confirm it.
    public private(set) var pendingControl: PendingControl?
    /// The last stop or removal Claude Code refused, kept until it is dismissed.
    public private(set) var controlProblem: ControlProblem?
    /// Set only by tests; otherwise the installed `claude` is run.
    var runControl: (@Sendable (SessionAction, String, [SessionControl.Override]) async -> ControlOutcome)?
    /// Looks into a session's worktree before a removal. Replaceable in tests.
    var inspectWorktree: @Sendable (Session) async -> WorktreeReport? = { await WorktreeInspector().report(for: $0) }
    /// A worktree that a removal left on disk, said once so it is not left behind unknowingly.
    public private(set) var leftover: String?
    /// The folders searched for repositories, as saved.
    public private(set) var workspaceRoots: [String] = []
    /// Called just before a terminal is brought forward. The app closes the menu-bar panel here:
    /// while the panel is open it keeps the keyboard, so the terminal would come to the front
    /// without taking the typing.
    public var willOpenTerminal: () -> Void = {}
    private var noticeGeneration = 0

    public var waitingCount: Int { snapshot.waitingCount }
    /// "Waited long" means as long as the second, louder reminder step.
    public var status: MenuBarStatus {
        MenuBarStatus(snapshot: snapshot, snoozes: snoozes, quiet: pins.quiet, overdueAfter: reminderSettings.secondStep, now: clock())
    }
    /// Sessions whose reminders are paused, as last read from the saved state.
    public private(set) var snoozes: [String: Snooze] = [:]

    /// The terminal "whichever is running" picks right now, for the menu's label.
    public var automaticTerminal: TerminalApp? {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.lastPathComponent }
        return TerminalApp.detect(running: running, installed: { installedTerminals.contains($0) })
    }
    public var now: Date { clock() }

    /// An option the user clicked for a session's question, not sent yet. It belongs to one
    /// asking of the question, and goes nowhere else.
    public struct PendingAnswer: Equatable, Sendable {
        public let sessionID: String
        public let option: Int
        public let questionID: String

        public init(sessionID: String, option: Int, questionID: String) {
            self.sessionID = sessionID
            self.option = option
            self.questionID = questionID
        }
    }

    public private(set) var pendingAnswer: PendingAnswer?

    /// What the user has typed as a reply and not sent yet, by session. Kept when the panel
    /// closes: a half-written reply is theirs to lose, not the panel's.
    public private(set) var replyDrafts: [String: String] = [:]
    /// The turn each draft was written for: a draft does not carry over to a later turn.
    private var replyDraftTurns: [String: String] = [:]

    public func setReplyDraft(sessionID: String, _ text: String) {
        guard let target = snapshot.sessions.first(where: { $0.id == sessionID })?.replyTarget else { return }
        replyDrafts[sessionID] = text.isEmpty ? nil : text
        replyDraftTurns[sessionID] = text.isEmpty ? nil : target.turnID
    }

    /// Puts the reply Claude Code suggests into the field, for the user to change or send. Only
    /// into an empty field: what the user has typed is never replaced.
    public func useSuggestedReply(sessionID: String) {
        guard let suggested = snapshot.sessions.first(where: { $0.id == sessionID })?.suggestedReply else { return }
        guard (replyDrafts[sessionID] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            show("The reply field already has text; clear it to use the suggestion")
            return
        }
        setReplyDraft(sessionID: sessionID, suggested)
    }

    /// Sends what the user typed to the session, as their reply. Judged again now: if the
    /// session has moved on, nothing is sent and the text stays in the field.
    public func sendReply(sessionID: String) {
        guard let text = replyDrafts[sessionID], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }), let target = session.replyTarget,
              replyDraftTurns[sessionID] == target.turnID else {
            show("That session has moved on; nothing was sent")
            return
        }
        guard let command = target.command(text: text) else {
            show("That reply is too long to send from here; open the session and paste it")
            return
        }
        // Sent only if the mod is waiting for it; nothing is left queued to arrive later.
        if let sendToCompanionIfWaiting, sendToCompanionIfWaiting(command, target.sessionID) {
            replyDrafts[sessionID] = nil
            replyDraftTurns[sessionID] = nil
            // How much was sent, never what.
            log?.record("reply \(sessionID): \(text.count) characters, taken")
            show("Sent your reply to \(session.name)")
            return
        }
        log?.record("reply \(sessionID): the session's mod was not waiting")
        let copy = self.copy
        Task {
            let copied = await copy(text)
            show(copied ? "\(session.name) is not listening. Your reply is on the clipboard: open the session and paste it." : "\(session.name) is not listening. Open the session and send your reply there.")
        }
    }

    /// Sends a reply typed somewhere other than the panel's field (the palette), for the turn it
    /// was typed for. Says whether it went, and what to tell the user.
    public func reply(sessionID: String, turnID: String, text: String) async -> (sent: Bool, message: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }), let target = session.replyTarget, target.turnID == turnID else {
            return (false, "That session has moved on; nothing was sent")
        }
        guard let command = target.command(text: text) else {
            return (false, "That reply is empty or too long to send from here")
        }
        if let sendToCompanionIfWaiting, sendToCompanionIfWaiting(command, target.sessionID) {
            log?.record("reply \(sessionID): \(text.count) characters, taken")
            return (true, "Sent your reply to \(session.name)")
        }
        log?.record("reply \(sessionID): the session's mod was not waiting")
        let copied = await copy(text)
        return (false, copied ? "\(session.name) is not listening. Your reply is on the clipboard: open the session and paste it." : "\(session.name) is not listening. Open the session and send your reply there.")
    }

    /// Called each time the sessions were read again. For what shows them elsewhere while it is
    /// open (the palette), so that it does not keep a list from the moment it opened.
    public var onSessionsRead: (() -> Void)?

    /// Rows whose last reply is shown whole instead of only its ending.
    public private(set) var expandedSaid: Set<String> = []

    /// The panel closed: the next time it opens on the sessions as they are, with nothing left
    /// half done. A reply opened in full, an answer chosen but not sent and a question about
    /// stopping or removing a session all belonged to that look at the panel.
    public func panelClosed() {
        showsSettings = false
        showsTriage = false
        expandedSaid = []
        pendingAnswer = nil
        cancelControl()
    }

    public func toggleSaid(sessionID: String) {
        if expandedSaid.remove(sessionID) == nil { expandedSaid.insert(sessionID) }
    }
    /// Hands a command to a session's mod; true when the mod took it at once. Set by the app.
    public var sendToCompanion: ((_ command: Data, _ conversationID: String) -> Bool)?
    /// The same, but nothing is kept for later when the mod is not waiting. Set by the app.
    public var sendToCompanionIfWaiting: ((_ command: Data, _ conversationID: String) -> Bool)?

    /// Chooses an option. Nothing is sent: `sendAnswer` does that, and only for this choice.
    public func chooseAnswer(sessionID: String, option: Int) {
        guard let target = snapshot.sessions.first(where: { $0.id == sessionID })?.answerTarget, target.options.indices.contains(option) else { return }
        pendingAnswer = PendingAnswer(sessionID: sessionID, option: option, questionID: target.questionID)
    }

    public func cancelAnswer() {
        pendingAnswer = nil
    }

    /// Sends the chosen option to the session as its question's answer.
    public func sendAnswer() {
        guard let pending = pendingAnswer else { return }
        pendingAnswer = nil
        show(answer(pending))
    }

    /// Sends one choice and returns what to tell the user. Judged again now, from the session as
    /// it is: if it has moved on or asks something else, nothing is sent.
    public func answer(_ choice: PendingAnswer) -> String {
        guard let session = snapshot.sessions.first(where: { $0.id == choice.sessionID }), let target = session.answerTarget,
              target.questionID == choice.questionID, let command = target.command(choosing: choice.option), let sendToCompanion else {
            return "That question is no longer open; nothing was sent"
        }
        let taken = sendToCompanion(command, target.sessionID)
        log?.record("answer \(session.id): option \(choice.option + 1) of \(target.options.count), \(taken ? "taken" : "queued")")
        return taken ? "Answered \(session.name): \(target.options[choice.option])" : "Sent to \(session.name). If it does not move on, open it and answer there."
    }

    /// The companion mod's reports, when the app listens for them.
    private let companion: CompanionHub?
    /// Why the app is not listening for the mod, when it tried and could not.
    public var companionProblem: String?
    /// How many of the listed sessions have the mod, as of the last read.
    public private(set) var companionSessions = 0
    public var listensForCompanion: Bool { companion != nil && companionProblem == nil }

    public init(
        store: SessionStore = .live(),
        launcher: (any TerminalLauncher)? = nil,
        locator: ClaudeLocator? = nil,
        settingsURL: URL = Settings.fileURL(),
        remindersURL: URL = ReminderState.fileURL(),
        pinsURL: URL? = nil,
        loginItem: LoginItem = .live(),
        companion: CompanionHub? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let settings = Settings.load(from: settingsURL)
        self.store = store
        self.companion = companion
        // Next to the reminders file, so a test that passes its own folder never touches the real pins.
        let pinsURL = pinsURL ?? remindersURL.deletingLastPathComponent().appendingPathComponent("pins.json")
        self.pinsURL = pinsURL
        self.pins = Pins.load(from: pinsURL)
        self.loginItem = loginItem
        self.injectedLauncher = launcher
        self.locator = locator ?? ClaudeLocator(override: settings.claudePath)
        self.injectedLocator = locator
        self.settingsURL = settingsURL
        self.clock = clock
        self.installedTerminals = TerminalApp.allCases.filter { $0.installedPath() != nil }
        self.chosenTerminal = settings.terminal.flatMap { TerminalApp(rawValue: $0.lowercased()) }
        self.prefersAgentView = settings.preferAgentView ?? false
        self.hotkey = settings.hotkey
        // Only the real app keeps a log; tests and bare executables leave the user's folder alone.
        self.log = Bundle.main.bundleURL.pathExtension == "app" ? ActivityLog() : nil
        // Created now, not when polling starts: macOS hands a clicked notification to the
        // delegate that exists when the app finishes launching, and drops it otherwise.
        let relay = ActionRelay()
        let delivery = UserNotificationDelivery { action in relay.send(action) }
        self.delivery = delivery
        self.reminderSettings = settings.reminders ?? ReminderSettings()
        self.transientErrors = settings.transientErrors ?? TransientErrors()
        self.engine = ReminderEngine(
            delivery: delivery, stateURL: remindersURL,
            // Read from the file each time, so a change here or by hand applies at the next refresh.
            settings: { Settings.load(from: settingsURL).reminders ?? ReminderSettings() },
            // Read from the file each time, so a pin set with `porchlight pin` applies too.
            muted: { Pins.load(from: pinsURL).quiet },
            now: clock)
        self.snoozes = ReminderState.load(from: remindersURL).snoozes
        relay.handler = { [weak self] action in
            Task { @MainActor in self?.handle(action) }
        }
    }

    /// Saves new reminder settings. They apply from the next refresh.
    public func updateReminders(_ change: (inout ReminderSettings) -> Void) {
        var updated = reminderSettings
        change(&updated)
        guard updated != reminderSettings else { return }
        reminderSettings = updated
        var settings = Settings.load(from: settingsURL)
        settings.reminders = updated
        do {
            try settings.save(to: settingsURL)
        } catch {
            show("Could not save the settings")
        }
    }

    /// Pauses or resumes reminders for a session, from the inbox.
    public func snooze(sessionID: String, _ choice: SnoozeChoice) async {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
        if let snooze = choice.snooze(for: session, now: clock()) {
            await engine.snooze(sessionID: sessionID, snooze)
            switch choice {
            case .hour: show("\(session.name) is snoozed for an hour")
            case .tomorrow: show("\(session.name) is snoozed until tomorrow morning")
            default: show("\(session.name) is snoozed until it asks something new")
            }
        } else if choice == .wake {
            await engine.clearSnooze(sessionID: sessionID)
            show("Reminders are back on for \(session.name)")
        } else {
            show("Cannot tell when \(session.name) started waiting")
        }
        snoozes = await engine.snoozes()
        log?.record("snooze \(sessionID): \(choice.rawValue)")
    }

    /// Replaces the sessions the model shows. The store calls this through `observe`.
    func apply(_ snapshot: StoreSnapshot) {
        // A choice is about the question that was showing: gone when that question is.
        if let pending = pendingAnswer, snapshot.sessions.first(where: { $0.id == pending.sessionID })?.answerTarget?.questionID != pending.questionID {
            pendingAnswer = nil
        }
        companionSessions = snapshot.sessions.filter { $0.companion != nil }.count
        if snapshot.problem == nil {
            companion?.keep(only: Set(snapshot.sessions.compactMap { $0.summary.sessionId?.lowercased() }))
        }
        self.snapshot = snapshot
        // A draft is a reply to one turn's end: gone when the session has moved on from it.
        for (sessionID, turn) in replyDraftTurns where snapshot.problem == nil {
            if snapshot.sessions.first(where: { $0.id == sessionID })?.replyTarget?.turnID != turn {
                replyDrafts[sessionID] = nil
                replyDraftTurns[sessionID] = nil
            }
        }
        sendDueRetries()
        onSessionsRead?()
    }

    public func setPrefersAgentView(_ value: Bool) {
        prefersAgentView = value
        var settings = Settings.load(from: settingsURL)
        settings.preferAgentView = value
        do {
            try settings.save(to: settingsURL)
            show(value ? "Sessions will open in agent view when it is already open" : "Sessions will open attached in their own tab")
        } catch {
            show("Could not save the setting")
        }
    }

    /// Changes the shortcut for the new-session palette. Nil removes it. A shortcut the system
    /// refuses, because another app holds it, is not saved and the old one stays.
    public func setHotkey(_ new: Hotkey?) {
        guard new != hotkey else { return }
        guard registerHotkey(new) else {
            _ = registerHotkey(hotkey)
            show("\(new?.display ?? "That shortcut") is already used by another app")
            return
        }
        hotkey = new
        var settings = Settings.load(from: settingsURL)
        settings.hotkey = new
        do {
            try settings.save(to: settingsURL)
            show(new.map { "\($0.display) opens a new session from any app" } ?? "Shortcut removed")
        } catch {
            show("Could not save the shortcut")
        }
    }

    /// Registers the saved shortcut when the app starts. Says so if it is no longer available.
    public func registerSavedHotkey() {
        guard let hotkey else { return }
        if !registerHotkey(hotkey) { show("\(hotkey.display) is already used by another app") }
    }

    /// Remembers which terminal "Open" uses. Nil goes back to picking the one that is running.
    public func chooseTerminal(_ terminal: TerminalApp?) {
        chosenTerminal = terminal
        var settings = Settings.load(from: settingsURL)
        settings.terminal = terminal?.rawValue
        do {
            try settings.save(to: settingsURL)
            show(terminal.map { "Sessions will open in \($0.displayName)" } ?? "Sessions will open in the terminal that is running")
        } catch {
            show("Could not save the terminal choice")
        }
    }

    /// Starts polling and watching. Runs until the task is cancelled.
    public func run() async {
        async let observing: Void = observe()
        // A report from the companion mod is a reason to read the sessions again at once.
        var triggers: [any ChangeTrigger] = [FSEventsChangeWatcher()]
        if let companion { triggers.append(companion) }
        async let refreshing: Void = RefreshLoop().run(store: store, triggers: triggers)
        _ = await (observing, refreshing)
    }

    private func observe() async {
        for await update in await store.updates() {
            apply(update.snapshot)
            await engine.process(update.snapshot)
            snoozes = await engine.snoozes()
            pins = Pins.load(from: pinsURL)
            notificationProblem = delivery?.problem
            await refreshSetup()
        }
    }

    /// Carries out a button pressed on a notification.
    func handle(_ action: ReminderAction) {
        log?.record("notification action: \(action)")
        switch action {
        case .open(let sessionID): open(sessionID: sessionID)
        case .copyReply(let sessionID): copyReply(sessionID: sessionID)
        case .snooze(let sessionID, let seconds):
            let until = clock().addingTimeInterval(seconds)
            Task {
                await engine.snooze(sessionID: sessionID, .until(until))
                snoozes = await engine.snoozes()
            }
        case .showInbox:
            showInbox()
        }
    }

    public func refresh() {
        Task { await store.refresh() }
    }

    /// The sessions as the inbox lists them, top to bottom, for the palette.
    public var rows: [InboxRow] {
        InboxGroups(sessions: snapshot.sessions, now: clock())
            .sections(
                now: clock(), snoozes: snoozes, overdueAfter: reminderSettings.secondStep, transientErrors: transientErrors,
                pins: pins, pinned: snapshot.sessions)
            .flatMap(\.rows)
    }

    /// The folders of the sessions that exist, for the list of places to start a new one.
    public var sessionDirectories: [String] { snapshot.sessions.map(\.summary.cwd) }

    /// Where `claude` is looked for, with the path from the settings as they are now.
    public nonisolated var claudeLocator: ClaudeLocator {
        injectedLocator ?? ClaudeLocator(override: Settings.load(from: settingsURL).claudePath)
    }

    /// Called when the palette started a session: reads the sessions straight away, so the new
    /// one is in the inbox without waiting for the next poll, and opens it if asked.
    public func sessionStarted(_ started: Dispatched, open: Bool) async {
        log?.record("dispatched \(started.id) in \(started.directory)")
        await store.refresh()
        apply(await store.snapshot)
        show("Started \(started.name ?? "a session") (\(started.id))")
        if open { self.open(sessionID: started.id) }
    }

    /// Looks again at what is set up. Cheap except for the version, which is read once.
    public func refreshSetup() async {
        let settings = Settings.load(from: settingsURL)
        let located = locator.locate()
        var facts = SetupFacts(
            claudePath: located?.path, claudeCandidates: locator.candidates(), claudeVersion: setupFacts.claudeVersion,
            hasWorkspaceRoot: !(settings.repos?.roots.isEmpty ?? true), notificationProblem: notificationProblem,
            hasShortcut: hotkey != nil, launchesAtLogin: loginItem.isEnabled(), hidden: settings.setupHidden ?? false)
        if facts.claudeVersion == nil, let located {
            facts.claudeVersion = await readClaudeVersion(located)
        }
        setupFacts = facts
        workspaceRoots = settings.repos?.roots ?? []
    }

    /// Stops searching a folder for repositories.
    public func removeWorkspaceRoot(_ root: String) async {
        var settings = Settings.load(from: settingsURL)
        var repos = settings.repos ?? RepoIndexSettings()
        repos.removeRoot(root)
        settings.repos = repos
        try? settings.save(to: settingsURL)
        await refreshSetup()
    }

    /// Switches opening at login on or off, and says so if the system would not.
    public func setLaunchesAtLogin(_ enabled: Bool) async {
        if let problem = loginItem.set(enabled) {
            show(problem, for: Self.problemNoticeSeconds)
        } else {
            show(enabled ? "Porchlight will open at login" : "Porchlight will no longer open at login")
        }
        await refreshSetup()
    }

    /// Does the step a button on the first-run card stands for.
    public func performSetup(_ kind: SetupStep.Kind) async {
        switch kind {
        case .workspace:
            guard let path = pickFolder(), RepoIndex.directoryExists(path) else { break }
            var settings = Settings.load(from: settingsURL)
            var repos = settings.repos ?? RepoIndexSettings()
            repos.addRoot(path)
            settings.repos = repos
            do {
                try settings.save(to: settingsURL)
                show("Looking for repositories in \(RepoPath.abbreviated(RepoPath.normalized(path)))")
            } catch {
                show("Could not save the settings")
            }
        case .notifications: openNotificationSettings()
        case .shortcut: setHotkey(.suggested)
        case .loginItem:
            if let problem = loginItem.set(true) {
                show(problem, for: Self.problemNoticeSeconds)
            } else {
                show("Porchlight will open at login")
            }
        case .claudeMissing, .claudeTooOld: break
        }
        await refreshSetup()
    }

    /// Hides the optional first-run steps for good. Problems still show.
    /// Chooses which model summarises sessions.
    public func setWrapUpEngine(_ engine: WrapUpEngine) {
        var settings = Settings.load(from: settingsURL)
        var wrapUp = settings.wrapUp ?? WrapUpSettings()
        guard wrapUp.engine != engine || settings.wrapUp == nil else { return }
        wrapUp.engine = engine
        settings.wrapUp = wrapUp
        do {
            try settings.save(to: settingsURL)
        } catch {
            show("Could not save the settings")
        }
    }

    public func hideSetup() {
        var settings = Settings.load(from: settingsURL)
        settings.setupHidden = true
        try? settings.save(to: settingsURL)
        setupFacts.hidden = true
    }

    /// Pins or unpins a session. A new pin is not quiet.
    public func togglePin(sessionID: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
        if pins.isPinned(sessionID) {
            pins.unpin(sessionID)
            show("Unpinned \(session.name)")
        } else {
            pins.pin(sessionID, now: clock())
            show("Pinned \(session.name)")
        }
        savePins()
    }

    /// Pins a session from the Triage tab: the answer "keep this one" to its verdict. Says what
    /// that means, since the row then leaves the tab.
    public func keep(sessionID: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }), !pins.isPinned(sessionID) else { return }
        pins.pin(sessionID, now: clock())
        show("Pinned \(session.name). It is under Pinned on the Sessions tab and will not be suggested for removal.", for: 8)
        savePins()
    }

    /// Turns a pinned session's reminders off or back on.
    public func setPinQuiet(sessionID: String, _ quiet: Bool) {
        guard pins.isPinned(sessionID), let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
        pins.pin(sessionID, quiet: quiet, now: clock())
        show(quiet ? "\(session.name) will not remind you while it is pinned" : "Reminders are back on for \(session.name)")
        savePins()
    }

    private func savePins() {
        do {
            try pins.save(to: pinsURL)
        } catch {
            show("Could not save the pin")
        }
        // A removal asked for before the pin no longer applies.
        if let pending = pendingControl, pending.action == .remove, pins.isPinned(pending.sessionID) { pendingControl = nil }
        // Withdraw or restore reminders straight away rather than at the next poll.
        Task { await engine.process(snapshot) }
    }

    /// Removes one session with plain `claude rm`, for the Triage tab's bulk removal. Nothing is
    /// forced, nothing is shown: the tab reports the outcomes together and reads the sessions
    /// again once at the end.
    public func removePlainly(sessionID: String) async -> ControlOutcome {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }), SessionAction.remove.applies(to: session), !pins.isPinned(sessionID) else {
            return .couldNotRun("That session can no longer be removed from here.")
        }
        let outcome: ControlOutcome
        if let runControl {
            outcome = await runControl(.remove, sessionID, [])
        } else if let claude = locator.locate() {
            outcome = await SessionControl(claude: claude).run(.remove, id: sessionID)
        } else {
            outcome = .couldNotRun("The claude command was not found")
        }
        log?.record("remove \(sessionID) (triage): \(outcome.succeeded ? "done" : "not done: \(outcome.message)")")
        return outcome
    }

    /// Reads the sessions now and shows the result.
    public func reload() async {
        await store.refresh()
        apply(await store.snapshot)
    }

    /// Asks to stop or remove a session. Nothing happens until `confirmControl`.
    public func askControl(_ action: SessionAction, sessionID: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }), action.applies(to: session) else { return }
        // A pinned session is kept until it is unpinned.
        if action == .remove, pins.isPinned(sessionID) { return }
        controlProblem = nil
        pendingControl = PendingControl(sessionID: sessionID, name: session.name, action: action)
        guard action == .remove else { return }
        // Say what the worktree holds before anything is removed. It arrives a moment later.
        Task {
            guard let report = await inspectWorktree(session), pendingControl?.sessionID == sessionID, pendingControl?.isForced == false else { return }
            pendingControl?.worktree = report.summary
        }
    }

    /// After Claude Code refused a removal and named what would be lost: asks, a second time and
    /// with its refusal in full, whether to remove anyway.
    public func askForcedRemoval() {
        guard let problem = controlProblem, !problem.overrides.isEmpty else { return }
        pendingControl = PendingControl(
            sessionID: problem.sessionID, name: problem.name, action: .remove, overrides: problem.overrides, refusal: problem.text)
        controlProblem = nil
    }

    public func dismissLeftover() {
        leftover = nil
    }

    public func cancelControl() {
        pendingControl = nil
    }

    public func dismissControlProblem() {
        controlProblem = nil
    }

    /// Carries out the stop or removal that was asked for, and returns what happened. A refusal
    /// is kept, in the CLI's words, until the user dismisses it.
    @discardableResult
    public func confirmControl() async -> ControlOutcome? {
        guard let pending = pendingControl else { return nil }
        pendingControl = nil
        return await control(pending)
    }

    /// Stops or removes a session that the user has already confirmed elsewhere (the palette).
    @discardableResult
    public func control(_ pending: PendingControl) async -> ControlOutcome {
        let session = snapshot.sessions.first { $0.id == pending.sessionID }
        let outcome: ControlOutcome
        if let runControl {
            outcome = await runControl(pending.action, pending.sessionID, pending.overrides)
        } else if let claude = locator.locate() {
            outcome = await SessionControl(claude: claude).run(pending.action, id: pending.sessionID, overrides: pending.overrides)
        } else {
            outcome = .couldNotRun("The claude command was not found")
        }
        let how = pending.isForced ? " (discarding, confirmed twice)" : ""
        log?.record("\(pending.action.rawValue) \(pending.sessionID)\(how): \(outcome.succeeded ? "done" : "not done: \(outcome.message)")")
        if outcome.succeeded {
            show(pending.action.done(name: pending.name))
            await store.refresh()
            apply(await store.snapshot)
            // Claude Code keeps a worktree that has uncommitted changes. Say so, with the path,
            // rather than leave a folder behind unmentioned.
            if pending.action == .remove, let session, let report = await inspectWorktree(session) {
                leftover = "\(pending.name) was removed from the list. \(report.leftover)"
            }
        } else {
            controlProblem = ControlProblem(sessionID: pending.sessionID, name: pending.name, action: pending.action, text: outcome.message)
        }
        return outcome
    }

    /// Opens Claude Code in a folder it has not been used in, so the user can answer its trust
    /// prompt. Porchlight never answers it for them.
    public func openToTrust(folder: String) {
        launch { claude in TerminalCommand(arguments: [claude], cwd: folder, title: "Claude Code") }
    }

    public func copy(_ text: String, saying message: String) {
        Task {
            let copied = (try? await CLIRunner().run(URL(fileURLWithPath: "/usr/bin/pbcopy"), [], input: text))?.succeeded ?? false
            show(copied ? message : "Could not copy")
        }
    }

    /// Opens a terminal on the conversation of a session that was removed, from its note.
    public func resume(_ note: SessionNote) {
        guard TerminalCommand.resume(note, claude: "claude") != nil else {
            show("That note does not say which conversation it was")
            return
        }
        launch { claude in TerminalCommand.resume(note, claude: claude) ?? TerminalCommand(arguments: [claude], cwd: note.directory, title: note.name) }
    }

    public func open(sessionID: String) {
        if let session = snapshot.sessions.first(where: { $0.id == sessionID }) {
            launch { claude in .attach(to: session, claude: claude) }
            return
        }
        // Not known yet: the app may have just been started by the click itself. Read the
        // sessions once and try again rather than doing nothing.
        Task {
            await store.refresh()
            let fresh = await store.snapshot
            snapshot = fresh
            guard let session = fresh.sessions.first(where: { $0.id == sessionID }) else {
                log?.record("open \(sessionID): no such session")
                show("That session is no longer there")
                return
            }
            launch { claude in .attach(to: session, claude: claude) }
        }
    }

    public func openAgentView() {
        // Started where a session already lives: in the home folder Claude Code would stop to
        // ask whether to trust it.
        let directory = TerminalCommand.trustedDirectory(among: snapshot.sessions)
        launch { claude in .agentView(claude: claude, cwd: directory) }
    }

    public func copyReply(sessionID: String) {
        guard let reply = snapshot.sessions.first(where: { $0.id == sessionID })?.suggestedReply else { return }
        Task {
            let copied = (try? await CLIRunner().run(URL(fileURLWithPath: "/usr/bin/pbcopy"), [], input: reply))?.succeeded ?? false
            show(copied ? "Suggested reply copied" : "Could not copy the reply")
        }
    }

    /// Opens a session that stopped on a passing failure and puts the line to resend on the
    /// clipboard. Judged again here, from the session as it is now: a session that has moved on
    /// or is asking something is left alone, whatever the row showed.
    /// Failures the user said not to retry by itself, by the failure's id.
    public private(set) var cancelledRetries: Set<String> = []
    /// When a retry was last sent for a failure, and whether the mod took it. One that was taken
    /// is not sent again; one that was only queued is, once the queue has dropped it.
    private var sentRetries: [String: (at: Date, taken: Bool)] = [:]
    /// Longer than the listener keeps a command nobody came for.
    static let resendQueuedRetryAfter: TimeInterval = 90

    /// Stops the automatic retry of the failure this session is stopped on. Retry still works.
    public func cancelRetry(sessionID: String) {
        guard let id = snapshot.sessions.first(where: { $0.id == sessionID })?.retryTarget?.failureID else { return }
        cancelledRetries.insert(id)
    }

    /// Turns automatic retry on, with this wait before the first one, or off with nil.
    public func setAutoRetry(after: TimeInterval?) {
        var settings = Settings.load(from: settingsURL)
        var transient = settings.transientErrors ?? TransientErrors()
        let attempts = transient.autoRetry?.attempts ?? AutoRetry.defaultAttempts
        transient.autoRetry = after.map { AutoRetry(after: $0, attempts: attempts) }
        settings.transientErrors = transient
        do {
            try settings.save(to: settingsURL)
            transientErrors = transient
            log?.record("automatic retry: \(after.map { "on, after \(Int($0)) s" } ?? "off")")
            sendDueRetries()
        } catch {
            show("Could not save the settings")
        }
    }

    /// Sends the retries that are due, each once. Only with automatic retry turned on, only for
    /// a failure the session's mod reported as one that may clear, and only the user's own line.
    func sendDueRetries() {
        let current = Set(snapshot.sessions.compactMap { $0.retryTarget?.failureID })
        sentRetries = sentRetries.filter { current.contains($0.key) }
        cancelledRetries.formIntersection(current)
        guard let auto = transientErrors.autoRetry, let sendToCompanion else { return }
        let now = clock()
        for session in snapshot.sessions {
            guard let target = session.retryTarget, !cancelledRetries.contains(target.failureID),
                  case .scheduled(let at, let attempt, let of) = auto.standing(for: target), at <= now else { continue }
            if let sent = sentRetries[target.failureID], sent.taken || now.timeIntervalSince(sent.at) < Self.resendQueuedRetryAfter { continue }
            guard let command = target.command(text: transientErrors.resend) else { continue }
            let taken = sendToCompanion(command, target.sessionID)
            sentRetries[target.failureID] = (now, taken)
            // The count and the class, never the line that was sent.
            log?.record("automatic retry \(session.id): attempt \(attempt) of \(of) after \(target.failureClass), \(taken ? "taken" : "queued")")
        }
    }

    public func retry(sessionID: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }),
              transientErrors.offersRetry(session) else {
            show("That session is not waiting on something that can be retried")
            return
        }
        // Through the session's mod when it is there to take it: the user pressed Retry, and
        // the line is theirs. Otherwise as before: the session opened, the line on the clipboard.
        // Nothing is left queued when the mod is not there: the user is about to send the line
        // by hand, and it must not arrive a second time.
        if let target = session.retryTarget, let sendToCompanionIfWaiting, let command = target.command(text: transientErrors.resend),
           sendToCompanionIfWaiting(command, target.sessionID) {
            sentRetries[target.failureID] = (clock(), true)
            log?.record("retry \(sessionID): sent through the mod after \(target.failureClass)")
            show("Sent \u{201C}\(transientErrors.resend)\u{201D} to \(session.name)")
            return
        }
        guard let claude = locator.locate() else {
            log?.record("retry: the claude command was not found")
            show("The claude command was not found")
            return
        }
        var configured = MacTerminalLauncher(preferred: chosenTerminal)
        configured.preferAgentView = prefersAgentView
        let launcher: any TerminalLauncher = injectedLauncher ?? configured
        let settings = transientErrors
        let copy = self.copy
        Task {
            let outcome = await Retry.run(session: session, settings: settings, claude: claude.path, launcher: launcher, copy: copy)
            log?.record("retry \(sessionID): \(outcome)")
            switch outcome {
            case .notRetryable: break
            case .launched(.failed(let reason), _): show(reason.prefix(1).uppercased() + reason.dropFirst())
            case .launched(.copiedToClipboard(let reason), _):
                show("\(reason.prefix(1).uppercased() + reason.dropFirst()). Command copied; paste it in a terminal, then send \u{201C}\(settings.resend)\u{201D}.")
            case .launched(_, resendCopied: true): show("Opened \(session.name). Paste \u{201C}\(settings.resend)\u{201D} there and press Return.")
            case .launched(_, resendCopied: false): show("Opened \(session.name). Send \u{201C}\(settings.resend)\u{201D} there to try again.")
            }
        }
    }

    /// Puts text on the clipboard. Tests replace it so they never touch the real one.
    var copy: @Sendable (String) async -> Bool = { text in
        (try? await CLIRunner().run(URL(fileURLWithPath: "/usr/bin/pbcopy"), [], input: text))?.succeeded ?? false
    }

    private func launch(_ makeCommand: @escaping @Sendable (String) -> TerminalCommand) {
        guard let claude = locator.locate() else {
            log?.record("open: the claude command was not found")
            show("The claude command was not found")
            return
        }
        var configured = MacTerminalLauncher(preferred: chosenTerminal)
        configured.preferAgentView = prefersAgentView
        let launcher: any TerminalLauncher = injectedLauncher ?? configured
        log?.record("focus before: \(PanelWindowObserver.focusReport())")
        willOpenTerminal()
        log?.record("focus after closing the panel: \(PanelWindowObserver.focusReport())")
        Task {
            let command = makeCommand(claude.path)
            let outcome = await launcher.open(command)
            log?.record("open \(command.sessionID ?? "agent view"): \(outcome)")
            log?.record("focus after opening: \(PanelWindowObserver.focusReport()) handOver=\(MacTerminalLauncher.lastHandOver)")
            switch outcome {
            case .opened(let terminal): show("Opened in \(terminal)")
            case .alreadyOpen(let terminal): show("Already open in \(terminal)")
            case .switchedInTab(let terminal): show("Showing \(command.title) in your Porchlight tab" + (terminal.map { " in \($0)" } ?? ""))
            case .agentViewFocused(let terminal):
                show(command.opensAgentView ? "Agent view is already open in \(terminal)" : "Agent view is open in \(terminal); pick \(command.title) there")
            // The panel is closed by now, so what went wrong stays up until it is seen.
            case .copiedToClipboard(let reason):
                show("\(reason.prefix(1).uppercased() + reason.dropFirst()). Command copied; paste it in a terminal.", for: Self.problemNoticeSeconds)
            case .failed(let reason): show(reason.prefix(1).uppercased() + reason.dropFirst(), for: Self.problemNoticeSeconds)
            }
        }
    }

    static let noticeSeconds: Double = 4
    /// Long enough to still be there when the panel is opened again to see why nothing happened.
    static let problemNoticeSeconds: Double = 120

    private func show(_ message: String, for seconds: Double = InboxModel.noticeSeconds) {
        notice = message
        noticeGeneration += 1
        let generation = noticeGeneration
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if generation == noticeGeneration { notice = nil }
        }
    }
}

/// Lets the notification delegate be created before the model that handles its actions exists.
private final class ActionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (@Sendable (ReminderAction) -> Void)?

    var handler: (@Sendable (ReminderAction) -> Void)? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func send(_ action: ReminderAction) {
        handler?(action)
    }
}
