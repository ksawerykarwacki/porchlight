import Foundation

/// Quoting for the one place a shell line is unavoidable: text typed into, or copied for, a terminal.
/// Processes Porchlight starts itself always get an argv array instead.
public enum ShellQuote {
    public static func quote(_ argument: String) -> String {
        let safe = argument.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_./:=@%+,".unicodeScalars.contains(scalar))
        }
        if safe && !argument.isEmpty { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func line(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}

/// A command to run in the user's terminal.
public struct TerminalCommand: Sendable, Equatable {
    public var arguments: [String]
    public var cwd: String?
    /// Shown as the tab or window title where the terminal supports it.
    public var title: String
    /// Set when the command attaches to a session, so an attach that is already open can be found.
    public var sessionID: String?
    /// True when the command opens agent view, so one that is already open can be reused.
    public var opensAgentView: Bool

    public init(arguments: [String], cwd: String? = nil, title: String, sessionID: String? = nil, opensAgentView: Bool = false) {
        self.arguments = arguments
        self.cwd = cwd
        self.title = title
        self.sessionID = sessionID
        self.opensAgentView = opensAgentView
    }

    /// What a person would type to run this from any directory.
    public var shellLine: String {
        let command = ShellQuote.line(arguments)
        guard let cwd else { return command }
        return "cd \(ShellQuote.quote(cwd)) && \(command)"
    }

    public static func attach(to session: Session, claude: String) -> TerminalCommand {
        TerminalCommand(
            arguments: [claude, "attach", session.id], cwd: session.location.repoRoot, title: session.name, sessionID: session.id)
    }

    /// Resumes the conversation a note is about, in the folder it ran in. Nil when the note's id
    /// is not the UUID the CLI reports, so that nothing else can ride on the command.
    public static func resume(_ note: SessionNote, claude: String) -> TerminalCommand? {
        guard WrapUp.isValidConversationID(note.sessionID), !note.directory.isEmpty else { return nil }
        return TerminalCommand(arguments: [claude, "--resume", note.sessionID], cwd: note.directory, title: note.name)
    }

    /// - Parameter cwd: where to start agent view. Claude Code asks whether to trust a folder it
    ///   has not been started in before, so pass one the user already works in, not the home folder.
    public static func agentView(claude: String, cwd: String? = nil) -> TerminalCommand {
        TerminalCommand(arguments: [claude, "agents"], cwd: cwd, title: "Claude agents", opensAgentView: true)
    }

    /// A folder Claude Code has certainly been started in: where the most recently active
    /// session lives.
    public static func trustedDirectory(among sessions: [Session]) -> String? {
        sessions
            .filter { !$0.location.repoRoot.isEmpty }
            .max { ($0.lastActivity ?? .distantPast) < ($1.lastActivity ?? .distantPast) }?
            .location.repoRoot
    }
}

public enum LaunchOutcome: Sendable, Equatable {
    /// The command is running in a terminal.
    case opened(terminal: String)
    /// The session was already attached in a terminal, which was brought to the front instead.
    case alreadyOpen(terminal: String)
    /// A `porchlight tab` was running and now shows the session, in the tab it already had.
    case switchedInTab(terminal: String?)
    /// Agent view was already open in a terminal, which was brought to the front. The user picks
    /// the session there: nothing outside agent view can select a row in it.
    case agentViewFocused(terminal: String)
    /// The terminal could not be driven; the command is on the clipboard for the user to paste.
    case copiedToClipboard(reason: String)
    case failed(String)
}

public protocol TerminalLauncher: Sendable {
    func open(_ command: TerminalCommand) async -> LaunchOutcome
}

/// User settings. Unknown keys are ignored and a missing or broken file means defaults.
public struct Settings: Sendable, Equatable, Codable {
    /// Which terminal "Open" uses, by name ("warp", "ghostty", "wezterm", "iterm2", "terminal"). Nil picks one.
    public var terminal: String?
    /// Path to the claude executable, overriding the search.
    public var claudePath: String?
    /// When true and agent view is already open in a terminal, opening a session switches to that
    /// terminal instead of attaching in a new tab.
    public var preferAgentView: Bool?
    /// When and how to remind. Nil uses the defaults.
    public var reminders: ReminderSettings?
    /// How to recognise a session that stopped on a passing failure. Nil uses the defaults.
    public var transientErrors: TransientErrors?
    /// Where to look for repositories to start sessions in. Nil means nowhere yet.
    public var repos: RepoIndexSettings?
    /// How new sessions are named. Nil uses the defaults.
    public var naming: NamingSettings?
    /// The shortcut that opens the new-session palette from any app. Nil means none.
    public var hotkey: Hotkey?
    /// True once the user hid the optional first-run steps.
    public var setupHidden: Bool?
    /// When a session counts as stale in triage. Nil uses the defaults.
    public var triage: TriageSettings?
    /// How a stale session is summarised. Nil uses the defaults.
    public var wrapUp: WrapUpSettings?

    public init(
        terminal: String? = nil, claudePath: String? = nil, preferAgentView: Bool? = nil, reminders: ReminderSettings? = nil,
        transientErrors: TransientErrors? = nil, repos: RepoIndexSettings? = nil, naming: NamingSettings? = nil, hotkey: Hotkey? = nil,
        setupHidden: Bool? = nil, triage: TriageSettings? = nil, wrapUp: WrapUpSettings? = nil
    ) {
        self.transientErrors = transientErrors
        self.terminal = terminal
        self.claudePath = claudePath
        self.preferAgentView = preferAgentView
        self.reminders = reminders
        self.repos = repos
        self.naming = naming
        self.hotkey = hotkey
        self.setupHidden = setupHidden
        self.triage = triage
        self.wrapUp = wrapUp
    }

    private enum CodingKeys: String, CodingKey {
        case terminal, claudePath, preferAgentView, reminders, transientErrors, repos, naming, hotkey, setupHidden, triage, wrapUp
    }

    /// Each value is read on its own, so one odd entry does not discard the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terminal = try? c.decodeIfPresent(String.self, forKey: .terminal)
        claudePath = try? c.decodeIfPresent(String.self, forKey: .claudePath)
        preferAgentView = try? c.decodeIfPresent(Bool.self, forKey: .preferAgentView)
        reminders = try? c.decodeIfPresent(ReminderSettings.self, forKey: .reminders)
        transientErrors = try? c.decodeIfPresent(TransientErrors.self, forKey: .transientErrors)
        repos = try? c.decodeIfPresent(RepoIndexSettings.self, forKey: .repos)
        naming = try? c.decodeIfPresent(NamingSettings.self, forKey: .naming)
        hotkey = try? c.decodeIfPresent(Hotkey.self, forKey: .hotkey)
        setupHidden = try? c.decodeIfPresent(Bool.self, forKey: .setupHidden)
        triage = try? c.decodeIfPresent(TriageSettings.self, forKey: .triage)
        wrapUp = try? c.decodeIfPresent(WrapUpSettings.self, forKey: .wrapUp)
    }

    public static func fileURL(in stateDirectory: URL = PorchlightPaths.stateDirectory()) -> URL {
        stateDirectory.appendingPathComponent("settings.json")
    }

    public static func load(from url: URL = Settings.fileURL()) -> Settings {
        guard let data = try? Data(contentsOf: url), let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return Settings()
        }
        return settings
    }

    public func save(to url: URL = Settings.fileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
