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
        // Only something that is running can be stopped. A stopped session reports the state
        // "stopped" (seen on 2.1.294), which like "done" has nothing left to stop.
        case .stop: return session.summary.state == .working || session.summary.state == .blocked
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
/// The plain forms are what is run. `claude rm` has flags that discard unpushed commits or force
/// a worktree away; Porchlight never adds them by itself. When the CLI refuses, its refusal is
/// shown, and if it names the exact value such a flag takes, the user can choose to remove with
/// that value after a second, explicit confirmation. Nothing else is ever passed.
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

    /// A flag and the value the CLI itself printed for it when it refused a removal.
    public struct Override: Sendable, Equatable {
        public let flag: String
        public let value: String
    }

    /// The flags that override a refusal. Only these two, and only with a value the CLI printed.
    static let overrideFlags = ["--discard-unpushed", "--force-remove-worktree"]

    /// What the CLI's refusal says could be passed to remove the session anyway. A value is
    /// taken only if it follows one of the two flags in the CLI's own text and looks like the
    /// `<commit>@<worktree>` or worktree id the CLI documents.
    public static func overrides(in refusal: String) -> [Override] {
        var found: [Override] = []
        for flag in overrideFlags {
            let pattern = NSRegularExpression.escapedPattern(for: flag) + #"[ =]+([A-Za-z0-9][A-Za-z0-9._@:/+-]{0,200})"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: refusal, range: NSRange(refusal.startIndex..., in: refusal)),
                  let range = Range(match.range(at: 1), in: refusal)
            else { continue }
            // A sentence may end right after the value.
            let value = String(refusal[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,:;"))
            if !value.isEmpty { found.append(Override(flag: flag, value: value)) }
        }
        return found
    }

    public static func arguments(for action: SessionAction, id: String, overrides: [Override] = []) -> [String]? {
        guard isValidID(id) else { return nil }
        switch action {
        case .stop: return overrides.isEmpty ? ["stop", id] : nil
        case .remove:
            guard overrides.allSatisfy({ overrideFlags.contains($0.flag) && !$0.value.isEmpty && $0.value.first != "-" }) else { return nil }
            return ["rm", id] + overrides.flatMap { [$0.flag, $0.value] }
        }
    }

    /// - Parameter overrides: values from `overrides(in:)` for a refusal of this same removal,
    ///   which the user has confirmed a second time. Never anything else.
    public func run(_ action: SessionAction, id: String, overrides: [Override] = []) async -> ControlOutcome {
        guard let arguments = Self.arguments(for: action, id: id, overrides: overrides) else {
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
    /// What is known about the session's worktree, said before a removal.
    public var worktree: String?
    /// Set for a removal the CLI already refused, which the user now wants anyway.
    public var overrides: [SessionControl.Override]
    /// The CLI's refusal that the overrides come from, shown again before it is overridden.
    public var refusal: String?

    public init(
        sessionID: String, name: String, action: SessionAction, worktree: String? = nil, overrides: [SessionControl.Override] = [],
        refusal: String? = nil
    ) {
        self.sessionID = sessionID
        self.name = name
        self.action = action
        self.worktree = worktree
        self.overrides = overrides
        self.refusal = refusal
    }

    public var isForced: Bool { !overrides.isEmpty }

    /// What the button that does it says.
    public var verb: String { isForced ? "Discard and remove" : action.verb }

    public var question: String {
        if isForced {
            return "Remove \(name) and discard what Claude Code listed? That work exists nowhere else and cannot be brought back.\n\n\(refusal ?? "")"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return [action.question(name: name), worktree].compactMap { $0 }.joined(separator: "\n\n")
    }
}

/// What is in a session's worktree that a removal could lose or leave behind.
public struct WorktreeReport: Sendable, Equatable {
    public let name: String
    public let path: String
    /// Files changed or added and not committed.
    public let uncommitted: Int
    /// Commits that are on no remote. Nil when that could not be worked out.
    public let unpushed: Int?

    public init(name: String, path: String, uncommitted: Int, unpushed: Int?) {
        self.name = name
        self.path = path
        self.uncommitted = uncommitted
        self.unpushed = unpushed
    }

    public var isClean: Bool { uncommitted == 0 && (unpushed ?? 0) == 0 }

    /// One sentence for the question before a removal.
    public var summary: String {
        if isClean, unpushed != nil { return "Its worktree \(name) has nothing uncommitted or unpushed, so Claude Code will delete it too." }
        var parts: [String] = []
        if uncommitted > 0 { parts.append("\(uncommitted) uncommitted \(uncommitted == 1 ? "file" : "files")") }
        if let unpushed, unpushed > 0 { parts.append("\(unpushed) \(unpushed == 1 ? "commit" : "commits") on no remote") }
        if parts.isEmpty { return "Its worktree \(name) has nothing uncommitted; whether everything is pushed could not be checked." }
        return "Its worktree \(name) has \(parts.joined(separator: " and ")). Claude Code keeps a worktree with uncommitted changes on disk, and refuses to remove a session whose commits are not pushed."
    }

    /// One sentence for after a removal that left the folder behind.
    public var leftover: String {
        var what = "Its worktree is still on disk"
        if uncommitted > 0 { what += " with \(uncommitted) uncommitted \(uncommitted == 1 ? "file" : "files")" }
        return "\(what): \(path)"
    }
}

/// Looks into a session's Claude worktree with plain git, to say what a removal would touch.
public struct WorktreeInspector: Sendable {
    public var git: URL
    public var runner: CLIRunner

    public init(git: URL = URL(fileURLWithPath: "/usr/bin/git"), runner: CLIRunner = CLIRunner()) {
        self.git = git
        self.runner = runner
    }

    /// Nil when the session is not in a Claude worktree, or the folder is gone.
    public func report(for session: Session) async -> WorktreeReport? {
        // A stopped session reports its repository as its folder; the job details still know
        // the worktree (seen on 2.1.294), so they are asked first.
        if let path = session.job?.worktreePath, !path.isEmpty {
            return await report(name: URL(fileURLWithPath: path).lastPathComponent, path: path)
        }
        guard let name = session.location.worktreeName else { return nil }
        let path = session.location.repoRoot + "/.claude/worktrees/" + name
        return await report(name: name, path: path)
    }

    public func report(name: String, path: String) async -> WorktreeReport? {
        guard RepoIndex.directoryExists(path) else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        guard let status = try? await runner.run(git, ["status", "--porcelain"], cwd: directory, timeout: 15), status.succeeded else { return nil }
        let uncommitted = status.stdout.split(whereSeparator: \.isNewline).count
        // Commits reachable from here and from no remote branch.
        let log = try? await runner.run(git, ["log", "--oneline", "HEAD", "--not", "--remotes"], cwd: directory, timeout: 15)
        let unpushed = log.flatMap { $0.succeeded ? $0.stdout.split(whereSeparator: \.isNewline).count : nil }
        return WorktreeReport(name: name, path: path, uncommitted: uncommitted, unpushed: unpushed)
    }
}

/// Why a stop or removal did not happen, in the CLI's words.
public struct ControlProblem: Sendable, Equatable {
    public let sessionID: String
    public let name: String
    public let action: SessionAction
    public let text: String

    public init(sessionID: String, name: String = "", action: SessionAction, text: String) {
        self.sessionID = sessionID
        self.name = name
        self.action = action
        self.text = text
    }

    /// What the refusal says could be passed to remove the session anyway; empty when it names
    /// nothing, in which case the only way on is the terminal.
    public var overrides: [SessionControl.Override] {
        action == .remove ? SessionControl.overrides(in: text) : []
    }

    public var title: String {
        switch action {
        case .stop: "Claude Code did not stop it"
        case .remove: "Claude Code did not remove it"
        }
    }
}
