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
    private let clock: @Sendable () -> Date
    private let settingsURL: URL
    private var engine: ReminderEngine?
    private var delivery: UserNotificationDelivery?
    private var log: ActivityLog?
    /// Why reminders are not reaching the screen, or nil when they can.
    public private(set) var notificationProblem: String?

    /// The terminal the user picked, or nil for "whichever is running".
    public private(set) var chosenTerminal: TerminalApp?
    public let installedTerminals: [TerminalApp]
    /// Switch to an agent view that is already open instead of attaching in a new tab.
    public private(set) var prefersAgentView = false

    public private(set) var snapshot = StoreSnapshot()
    /// Which row or button the pointer is over.
    public let hover = HoverTracker()
    /// The result of the last action, shown briefly at the bottom of the inbox.
    public private(set) var notice: String?
    private var noticeGeneration = 0

    public var waitingCount: Int { snapshot.waitingCount }
    public var status: MenuBarStatus { MenuBarStatus(snapshot: snapshot, snoozes: snoozes, now: clock()) }
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
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let settings = Settings.load(from: settingsURL)
        self.store = store
        self.injectedLauncher = launcher
        self.locator = locator ?? ClaudeLocator(override: settings.claudePath)
        self.settingsURL = settingsURL
        self.clock = clock
        self.installedTerminals = TerminalApp.allCases.filter { $0.installedPath() != nil }
        self.chosenTerminal = settings.terminal.flatMap { TerminalApp(rawValue: $0.lowercased()) }
        self.prefersAgentView = settings.preferAgentView ?? false
        // Only the real app keeps a log; tests and bare executables leave the user's folder alone.
        self.log = Bundle.main.bundleURL.pathExtension == "app" ? ActivityLog() : nil
        // Created now, not when polling starts: macOS hands a clicked notification to the
        // delegate that exists when the app finishes launching, and drops it otherwise.
        self.delivery = UserNotificationDelivery { [weak self] action in
            Task { @MainActor in self?.handle(action) }
        }
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
        let engine = makeEngine()
        self.engine = engine
        for await update in await store.updates() {
            snapshot = update.snapshot
            await engine.process(update.snapshot)
            snoozes = await engine.snoozes()
            notificationProblem = delivery?.problem
        }
    }

    private func makeEngine() -> ReminderEngine {
        let delivery = self.delivery ?? UserNotificationDelivery { _ in }
        return ReminderEngine(delivery: delivery)
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
                await engine?.snooze(sessionID: sessionID, .until(until))
                if let engine { snoozes = await engine.snoozes() }
            }
        case .showInbox:
            // The panel cannot be opened from here; bringing the app forward is the nearest thing.
            break
        }
    }

    public func refresh() {
        Task { await store.refresh() }
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

    private func launch(_ makeCommand: @escaping @Sendable (String) -> TerminalCommand) {
        guard let claude = locator.locate() else {
            log?.record("open: the claude command was not found")
            show("The claude command was not found")
            return
        }
        var configured = MacTerminalLauncher(preferred: chosenTerminal)
        configured.preferAgentView = prefersAgentView
        let launcher: any TerminalLauncher = injectedLauncher ?? configured
        Task {
            let command = makeCommand(claude.path)
            let outcome = await launcher.open(command)
            log?.record("open \(command.sessionID ?? "agent view"): \(outcome)")
            switch outcome {
            case .opened(let terminal): show("Opened in \(terminal)")
            case .alreadyOpen(let terminal): show("Already open in \(terminal)")
            case .switchedInTab(let terminal): show("Showing \(command.title) in your Porchlight tab" + (terminal.map { " in \($0)" } ?? ""))
            case .agentViewFocused(let terminal):
                show(command.opensAgentView ? "Agent view is already open in \(terminal)" : "Agent view is open in \(terminal); pick \(command.title) there")
            case .copiedToClipboard(let reason): show("\(reason.prefix(1).uppercased() + reason.dropFirst()). Command copied; paste it in a terminal.")
            case .failed(let reason): show(reason.prefix(1).uppercased() + reason.dropFirst())
            }
        }
    }

    private func show(_ message: String) {
        notice = message
        noticeGeneration += 1
        let generation = noticeGeneration
        Task {
            try? await Task.sleep(for: .seconds(4))
            if generation == noticeGeneration { notice = nil }
        }
    }
}
