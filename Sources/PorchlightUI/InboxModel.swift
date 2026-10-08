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

    /// The terminal the user picked, or nil for "whichever is running".
    public private(set) var chosenTerminal: TerminalApp?
    public let installedTerminals: [TerminalApp]
    /// Switch to an agent view that is already open instead of attaching in a new tab.
    public private(set) var prefersAgentView = false

    public private(set) var snapshot = StoreSnapshot()
    /// The result of the last action, shown briefly at the bottom of the inbox.
    public private(set) var notice: String?
    private var noticeGeneration = 0

    public var waitingCount: Int { snapshot.waitingCount }
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
        for await update in await store.updates() {
            snapshot = update.snapshot
        }
    }

    public func refresh() {
        Task { await store.refresh() }
    }

    public func open(sessionID: String) {
        guard let session = snapshot.sessions.first(where: { $0.id == sessionID }) else { return }
        launch { claude in .attach(to: session, claude: claude) }
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
            show("The claude command was not found")
            return
        }
        var configured = MacTerminalLauncher(preferred: chosenTerminal)
        configured.preferAgentView = prefersAgentView
        let launcher: any TerminalLauncher = injectedLauncher ?? configured
        Task {
            let command = makeCommand(claude.path)
            switch await launcher.open(command) {
            case .opened(let terminal): show("Opened in \(terminal)")
            case .alreadyOpen(let terminal): show("Already open in \(terminal)")
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
