import Foundation

/// What the installed `claude` can be asked for when starting a session, read from `claude --help`
/// so that Porchlight only passes flags this version documents.
public struct DispatchCapabilities: Sendable, Equatable {
    public var background = false
    public var name = false
    public var model = false
    public var agent = false
    public var worktree = false
    /// The effort levels the CLI lists; empty when it has no `--effort`.
    public var effortLevels: [String] = []
    /// The permission modes the CLI lists; empty when it has no `--permission-mode`.
    public var permissionModes: [String] = []

    public init() {}

    /// Modes Porchlight offers. Skipping every permission check is left to the terminal, where
    /// the person typing it sees what they are doing.
    public var offeredPermissionModes: [String] {
        permissionModes.filter { $0 != "bypassPermissions" }
    }

    public init(help: String) {
        // Option descriptions wrap over several lines; work on one line of text. A list of values
        // is only taken from an option's own description, up to where the next option starts.
        let text = ANSI.strip(help).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        func has(_ flag: String) -> Bool {
            text.range(of: "(^|[ ,])\(NSRegularExpression.escapedPattern(for: flag))([ ,]|$)", options: .regularExpression) != nil
        }
        background = has("--bg")
        name = has("--name")
        model = has("--model")
        agent = has("--agent")
        worktree = has("--worktree")
        if has("--effort"), let match = text.firstMatch(of: /--effort <[^>]*> (?:(?! --).)*?\(([a-z, ]+)\)/) {
            effortLevels = match.output.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if has("--permission-mode"), let match = text.firstMatch(of: /--permission-mode <[^>]*> (?:(?! --).)*?\(choices: ([^)]*)\)/) {
            permissionModes = match.output.1.split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }.filter { !$0.isEmpty }
        }
    }
}

/// A session to start.
public struct DispatchRequest: Sendable, Equatable {
    public enum Worktree: Sendable, Equatable {
        /// Let Claude Code name the worktree.
        case unnamed
        case named(String)
    }

    /// The folder the session starts in.
    public var directory: String
    public var prompt: String
    public var name: String?
    public var model: String?
    public var effort: String?
    public var agent: String?
    public var permissionMode: String?
    public var worktree: Worktree?

    public init(
        directory: String, prompt: String, name: String? = nil, model: String? = nil, effort: String? = nil, agent: String? = nil,
        permissionMode: String? = nil, worktree: Worktree? = nil
    ) {
        self.directory = directory
        self.prompt = prompt
        self.name = name
        self.model = model
        self.effort = effort
        self.agent = agent
        self.permissionMode = permissionMode
        self.worktree = worktree
    }
}

/// A session that was started.
public struct Dispatched: Sendable, Equatable, Codable {
    /// The short id `claude attach` takes.
    public let id: String
    public let name: String?
    public let directory: String

    public init(id: String, name: String?, directory: String) {
        self.id = id
        self.name = name
        self.directory = directory
    }
}

public enum DispatchError: Error, Sendable, Equatable {
    case emptyPrompt
    case notAFolder(String)
    /// The installed CLI has no `--bg`.
    case backgroundNotSupported
    /// The request asks for something `claude --help` does not list, such as an unknown effort level.
    case notSupported(String)
    /// `claude` refused or failed. `command` is what was run, for the user to copy and try.
    case failed(DispatchFailure, command: String)
    /// `claude` reported success but printed no session id.
    case noSessionID(output: String, command: String)
    case couldNotRun(String)

    /// What to show the user. The CLI's own words are passed on unchanged.
    public var message: String {
        switch self {
        case .emptyPrompt: "Write what the session should do first."
        case .notAFolder(let path): "\(path) is not a folder."
        case .backgroundNotSupported: "This version of Claude Code cannot start background sessions (no --bg). Update Claude Code."
        case .notSupported(let what): "This version of Claude Code does not support \(what)."
        case .failed(.workspaceNotTrusted(let path), _):
            "Claude Code has not been used in \(path ?? "this folder") yet. Open it there once and accept the trust prompt, then try again."
        case .failed(.other(let text), _): text.isEmpty ? "Claude Code could not start the session." : text
        case .noSessionID(let output, _):
            "Claude Code did not say which session it started." + (output.isEmpty ? "" : "\n\(output)")
        case .couldNotRun(let text): "Could not run claude: \(text)"
        }
    }

    /// The command that failed, as a line for a terminal, when there is one.
    public var command: String? {
        switch self {
        case .failed(_, let command), .noSessionID(_, let command): command
        default: nil
        }
    }

    /// The folder to open Claude Code in to accept its trust prompt, when that is what is missing.
    public var untrustedFolder: String? {
        if case .failed(.workspaceNotTrusted(let path), _) = self { return path }
        return nil
    }

    public var isUntrustedFolder: Bool {
        if case .failed(.workspaceNotTrusted, _) = self { return true }
        return false
    }
}

/// Starts background sessions by running the unmodified `claude` CLI.
public struct Dispatcher: Sendable {
    public var claude: URL
    public var runner: CLIRunner
    public var environment: [String: String]?

    public init(claude: URL, runner: CLIRunner = CLIRunner(), environment: [String: String]? = nil) {
        self.claude = claude
        self.runner = runner
        self.environment = environment
    }

    /// Reads what this `claude` supports. Nothing is assumed when the help cannot be read.
    public func capabilities() async -> DispatchCapabilities {
        guard let result = try? await runner.run(claude, ["--help"], environment: environment, timeout: 10), result.succeeded else {
            return DispatchCapabilities()
        }
        return DispatchCapabilities(help: result.stdout)
    }

    /// The arguments for a request: only flags this CLI lists, each value its own argument, and
    /// the prompt after `--` so that nothing in it can be read as a flag.
    public static func arguments(for request: DispatchRequest, capabilities: DispatchCapabilities) throws -> [String] {
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw DispatchError.emptyPrompt }
        guard capabilities.background else { throw DispatchError.backgroundNotSupported }

        func value(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        var arguments = ["--bg"]
        if let name = value(request.name) {
            // Without --name the session still starts; Claude Code names it.
            if capabilities.name { arguments += ["--name", name] }
        }
        if let model = value(request.model) {
            guard capabilities.model else { throw DispatchError.notSupported("choosing a model (--model)") }
            arguments += ["--model", model]
        }
        if let effort = value(request.effort) {
            guard capabilities.effortLevels.contains(effort) else { throw DispatchError.notSupported("the effort level \"\(effort)\"") }
            arguments += ["--effort", effort]
        }
        if let agent = value(request.agent) {
            guard capabilities.agent else { throw DispatchError.notSupported("choosing an agent (--agent)") }
            arguments += ["--agent", agent]
        }
        if let mode = value(request.permissionMode) {
            guard capabilities.offeredPermissionModes.contains(mode) else { throw DispatchError.notSupported("the permission mode \"\(mode)\"") }
            arguments += ["--permission-mode", mode]
        }
        switch request.worktree {
        case .unnamed?:
            guard capabilities.worktree else { throw DispatchError.notSupported("worktrees (--worktree)") }
            arguments += ["--worktree"]
        case .named(let worktree)?:
            guard capabilities.worktree else { throw DispatchError.notSupported("worktrees (--worktree)") }
            if let worktree = value(worktree) {
                // One argument, so a name that starts with a dash is still a name.
                arguments += ["--worktree=\(worktree)"]
            } else {
                arguments += ["--worktree"]
            }
        case nil:
            break
        }
        return arguments + ["--", prompt]
    }

    public func dispatch(_ request: DispatchRequest, capabilities: DispatchCapabilities? = nil) async throws -> Dispatched {
        let directory = RepoPath.normalized(request.directory)
        guard RepoIndex.directoryExists(directory) else { throw DispatchError.notAFolder(directory) }
        let known: DispatchCapabilities
        if let capabilities {
            known = capabilities
        } else {
            known = await self.capabilities()
        }
        let arguments = try Self.arguments(for: request, capabilities: known)
        let command = TerminalCommand(arguments: [claude.path] + arguments, cwd: directory, title: "").shellLine

        let result: CLIResult
        do {
            result = try await runner.run(
                claude, arguments, cwd: URL(fileURLWithPath: directory, isDirectory: true), environment: environment, timeout: 60)
        } catch CLIError.timedOut(let seconds) {
            throw DispatchError.couldNotRun("no answer after \(Int(seconds)) seconds")
        } catch CLIError.launchFailed(let reason) {
            throw DispatchError.couldNotRun(reason)
        }
        guard result.succeeded else {
            // Some failures are printed on stdout; show whichever the CLI used.
            let words = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? result.stdout : result.stderr
            throw DispatchError.failed(DispatchFailure(stderr: words), command: command)
        }
        guard let id = DispatchOutput.sessionID(from: result.stdout) else {
            throw DispatchError.noSessionID(output: ANSI.strip(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines), command: command)
        }
        return Dispatched(id: id, name: DispatchOutput.sessionName(from: result.stdout) ?? request.name, directory: directory)
    }
}
