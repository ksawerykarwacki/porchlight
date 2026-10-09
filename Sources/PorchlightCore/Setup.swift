import Foundation

/// What Porchlight can see of its own set-up, gathered by the frontend.
public struct SetupFacts: Sendable, Equatable {
    /// Where `claude` was found, or nil with the places that were tried.
    public var claudePath: String?
    public var claudeCandidates: [String]
    /// The version `claude --version` printed, when it could be read.
    public var claudeVersion: CLIVersion?
    public var hasWorkspaceRoot: Bool
    /// Why reminders are not reaching the screen, or nil when they can.
    public var notificationProblem: String?
    public var hasShortcut: Bool
    /// Whether the app opens at login; nil when that cannot be told or set from this copy.
    public var launchesAtLogin: Bool?
    /// The optional steps were hidden by the user.
    public var hidden: Bool

    public init(
        claudePath: String? = nil, claudeCandidates: [String] = [], claudeVersion: CLIVersion? = nil, hasWorkspaceRoot: Bool = false,
        notificationProblem: String? = nil, hasShortcut: Bool = false, launchesAtLogin: Bool? = nil, hidden: Bool = false
    ) {
        self.claudePath = claudePath
        self.claudeCandidates = claudeCandidates
        self.claudeVersion = claudeVersion
        self.hasWorkspaceRoot = hasWorkspaceRoot
        self.notificationProblem = notificationProblem
        self.hasShortcut = hasShortcut
        self.launchesAtLogin = launchesAtLogin
        self.hidden = hidden
    }
}

/// One thing to put right, or one optional step, on the first-run card.
public struct SetupStep: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case claudeMissing, claudeTooOld, workspace, notifications, shortcut, loginItem
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    /// The label of the button that does the step, when Porchlight can do it.
    public let action: String?
    /// A problem stops Porchlight from working and cannot be hidden; the rest is optional.
    public let isProblem: Bool

    public var id: String { kind.rawValue }
}

public enum Setup {
    /// The oldest Claude Code that Porchlight has been checked against. Provisional: it is the
    /// only version verified so far, not the first that has `claude agents --json`.
    public static let minimumClaudeVersion = CLIVersion([2, 1, 294])

    /// What is left to do, problems first. Optional steps are left out once hidden.
    public static func steps(for facts: SetupFacts) -> [SetupStep] {
        var steps: [SetupStep] = []
        if facts.claudePath == nil {
            let tried = facts.claudeCandidates.prefix(4).joined(separator: ", ")
            steps.append(SetupStep(
                kind: .claudeMissing, title: "Claude Code was not found",
                detail: "Porchlight shows and starts Claude Code sessions, so it needs the claude command. Install Claude Code, or set \"claudePath\" in settings.json."
                    + (tried.isEmpty ? "" : " Looked in: \(tried)."),
                action: nil, isProblem: true))
        } else if let version = facts.claudeVersion, version < minimumClaudeVersion {
            steps.append(SetupStep(
                kind: .claudeTooOld, title: "Claude Code \(version) is older than Porchlight expects",
                detail: "Porchlight is checked against \(minimumClaudeVersion) and later. Run: claude update",
                action: nil, isProblem: true))
        }
        guard !facts.hidden else { return steps }
        if !facts.hasWorkspaceRoot {
            steps.append(SetupStep(
                kind: .workspace, title: "Say where your repositories live",
                detail: "Porchlight looks there for places to start a session. Folders of sessions you already have are listed anyway.",
                action: "Add a folder…", isProblem: false))
        }
        if let problem = facts.notificationProblem {
            steps.append(SetupStep(kind: .notifications, title: "Reminders cannot reach you", detail: problem, action: "Open Notification settings", isProblem: false))
        }
        if !facts.hasShortcut {
            steps.append(SetupStep(
                kind: .shortcut, title: "Open the palette from any app",
                detail: "A shortcut shows your sessions and starts new ones wherever you are.",
                action: "Use \(Hotkey.suggested.display)", isProblem: false))
        }
        if facts.launchesAtLogin == false {
            steps.append(SetupStep(
                kind: .loginItem, title: "Open Porchlight at login",
                detail: "So the lantern is there after a restart without you starting it.",
                action: "Open at login", isProblem: false))
        }
        return steps
    }

    /// Whether the optional steps can still be hidden: there are some, and they are showing.
    public static func canHide(_ steps: [SetupStep]) -> Bool {
        steps.contains { !$0.isProblem }
    }
}

/// Moving settings between machines: the settings file as it is, checked before it replaces
/// anything.
public enum SettingsTransfer {
    public enum Failure: Error, Equatable {
        case unreadable(String)
        /// The file is not JSON, or not an object.
        case notSettings
    }

    /// The settings in force, as the text of a settings file.
    public static func export(_ settings: Settings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(settings)
    }

    /// Reads a settings file from elsewhere. Unknown keys are ignored and odd values fall back
    /// one by one, as when the app reads its own file; a file that is not a JSON object at all
    /// is refused, so a wrong file cannot wipe the settings.
    public static func read(_ data: Data) throws -> Settings {
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else { throw Failure.notSettings }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else { throw Failure.notSettings }
        return settings
    }
}
