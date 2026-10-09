import Foundation

/// Something to do to a session that cannot be taken back by Porchlight.
public enum SessionAction: String, Sendable, Equatable, CaseIterable {
    /// `claude stop`: the process ends, the conversation is kept and can be opened again.
    case stop
    /// `claude rm`: the session leaves the list, and its worktree goes too when that is safe.
    case remove

    public var verb: String {
        switch self {
        case .stop: "Stop"
        case .remove: "Remove"
        }
    }

    /// What the user is told before it happens.
    public func question(name: String) -> String {
        switch self {
        case .stop: "Stop \(name)? It keeps its conversation; opening it starts it again."
        case .remove:
            "Remove \(name)? It leaves the list. Claude Code deletes its worktree only if nothing in it would be lost; the transcript stays on disk."
        }
    }

    public func done(name: String) -> String {
        switch self {
        case .stop: "Stopped \(name)"
        case .remove: "Removed \(name)"
        }
    }

    /// Whether the action is offered for a session. Both are for background sessions only: one
    /// that runs in a terminal of its own is ended there. A finished session cannot be stopped.
    public func applies(to session: Session) -> Bool {
        guard session.summary.kind == "background" else { return false }
        switch self {
        case .stop: return session.summary.state != .done
        case .remove: return true
        }
    }
}

public enum ControlOutcome: Sendable, Equatable {
    /// Done. The text is what the CLI printed, which may be empty.
    case done(String)
    /// The CLI said no. The text is its own, unchanged: for `rm` it names what would be lost
    /// and how to discard it, which is for the user to read and decide on in a terminal.
    case refused(String)
    case couldNotRun(String)

    public var succeeded: Bool {
        if case .done = self { return true }
        return false
    }

    public var message: String {
        switch self {
        case .done(let text), .refused(let text), .couldNotRun(let text): text
        }
    }
}

/// Stops and removes sessions by running the unmodified `claude` CLI.
///
/// Only the documented plain forms are run. `claude rm` has flags that discard unpushed commits
/// or force a worktree away; Porchlight never passes them. When the CLI refuses, the refusal is
/// shown and the decision stays with the user.
public struct SessionControl: Sendable {
    public var claude: URL
    public var runner: CLIRunner
    public var environment: [String: String]?

    public init(claude: URL, runner: CLIRunner = CLIRunner(), environment: [String: String]? = nil) {
        self.claude = claude
        self.runner = runner
        self.environment = environment
    }

    /// The short id the CLI prints and lists: letters, digits and hyphens. Anything else, above
    /// all something starting with a dash, is not passed on.
    public static func isValidID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.first != "-" && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    public static func arguments(for action: SessionAction, id: String) -> [String]? {
        guard isValidID(id) else { return nil }
        switch action {
        case .stop: return ["stop", id]
        case .remove: return ["rm", id]
        }
    }

    public func run(_ action: SessionAction, id: String) async -> ControlOutcome {
        guard let arguments = Self.arguments(for: action, id: id) else {
            return .couldNotRun("\"\(id)\" is not a session id.")
        }
        let result: CLIResult
        do {
            result = try await runner.run(claude, arguments, environment: environment, timeout: 60)
        } catch CLIError.timedOut(let seconds) {
            return .couldNotRun("claude \(arguments[0]) did not answer in \(Int(seconds)) seconds.")
        } catch {
            return .couldNotRun("Could not run claude: \(error.localizedDescription)")
        }
        let output = ANSI.strip(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded else {
            let words = ANSI.strip(result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let said = words.isEmpty ? output : words
            return .refused(said.isEmpty ? "claude \(arguments[0]) failed (exit \(result.exitCode))." : said)
        }
        return .done(output)
    }
}

/// A stop or removal that has been asked for and not yet confirmed.
public struct PendingControl: Sendable, Equatable {
    public let sessionID: String
    public let name: String
    public let action: SessionAction

    public init(sessionID: String, name: String, action: SessionAction) {
        self.sessionID = sessionID
        self.name = name
        self.action = action
    }

    public var question: String { action.question(name: name) }
}

/// Why a stop or removal did not happen, in the CLI's words.
public struct ControlProblem: Sendable, Equatable {
    public let sessionID: String
    public let action: SessionAction
    public let text: String

    public init(sessionID: String, action: SessionAction, text: String) {
        self.sessionID = sessionID
        self.action = action
        self.text = text
    }

    public var title: String {
        switch action {
        case .stop: "Claude Code did not stop it"
        case .remove: "Claude Code did not remove it"
        }
    }
}
