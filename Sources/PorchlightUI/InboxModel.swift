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
    /// Which row or button the pointer is over.
    public let hover = HoverTracker()
    /// The result of the last action, shown briefly at the bottom of the inbox.
    public private(set) var notice: String?
    /// A stop or removal waiting for the user to confirm it.
    public private(set) var pendingControl: PendingControl?
    /// The last stop or removal Claude Code refused, kept until it is dismissed.
    public private(set) var controlProblem: ControlProblem?
    /// Set only by tests; otherwise the installed `claude` is run.
    var runControl: (@Sendable (SessionAction, String) async -> ControlOutcome)?
    /// Called just before a terminal is brought forward. The app closes the menu-bar panel here:
    /// while the panel is open it keeps the keyboard, so the terminal would come to the front
    /// without taking the typing.
    public var willOpenTerminal: () -> Void = {}
    private var noticeGeneration = 0

    public var waitingCount: Int { snapshot.waitingCount }
    /// "Waited long" means as long as the second, louder reminder step.
    public var status: MenuBarStatus {
        MenuBarStatus(snapshot: snapshot, snoozes: snoozes, overdueAfter: reminderSettings.secondStep, now: clock())
    }
    /// Sessions whose reminders are paused, as last read from the saved state.
    public private(set) var snoozes: [String: Snooze] = [:]

    /// The terminal "whichever is running" picks right now, for the menu's label.
    public var automaticTerminal: TerminalApp? {
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.lastPathComponent }
        return TerminalApp.detect(running: running, installed: { installedTerminals.contains($0) })
    }
    public var now: Date { clock() }

    public init(
        store: SessionStore = .live(),
        launcher: (any TerminalLauncher)? = nil,
        locator: ClaudeLocator? = nil,
        settingsURL: URL = Settings.fileURL(),
        remindersURL: URL = ReminderState.fileURL(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let settings = Settings.load(from: settingsURL)
        self.store = store
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
        self.snapshot = snapshot
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
        async let refreshing: Void = RefreshLoop().run(store: store, triggers: [FSEventsChangeWatcher()])
        _ = await (observing, refreshing)
    }

    private func observe() async {
        for await update in await store.updates() {
            apply(update.snapshot)
            await engine.process(update.snapshot)
            snoozes = await engine.snoozes()
            notificationProblem = delivery?.problem
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
            // The panel cannot be opened from here; bringing the app forward is the nearest thing.
            break
        }
    }

    public func refresh() {
        Task { await store.refresh() }
    }

    /// The sessions as the inbox lists them, top to bottom, for the palette.
    public var rows: [InboxRow] {
        InboxGroups(sessions: snapshot.sessions, now: clock())
            .sections(now: clock(), snoozes: snoozes, overdueAfter: reminderSettings.secondStep, transientErrors: transientErrors)
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

    /// Asks to stop or remove a session. Nothing happens until `confirmControl`.
    public func askControl(_ action: SessionAction, sessionID: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }), action.applies(to: session) else { return }
        controlProblem = nil
        pendingControl = PendingControl(sessionID: sessionID, name: session.name, action: action)
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
        let outcome: ControlOutcome
        if let runControl {
            outcome = await runControl(pending.action, pending.sessionID)
        } else if let claude = locator.locate() {
            outcome = await SessionControl(claude: claude).run(pending.action, id: pending.sessionID)
        } else {
            outcome = .couldNotRun("The claude command was not found")
        }
        log?.record("\(pending.action.rawValue) \(pending.sessionID): \(outcome.succeeded ? "done" : "not done: \(outcome.message)")")
        if outcome.succeeded {
            show(pending.action.done(name: pending.name))
            await store.refresh()
            apply(await store.snapshot)
        } else {
            controlProblem = ControlProblem(sessionID: pending.sessionID, action: pending.action, text: outcome.message)
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
    public func retry(sessionID: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }),
              transientErrors.isTransientFailure(session) else {
            show("That session is not waiting on something that can be retried")
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
