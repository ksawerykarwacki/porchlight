import Foundation

/// The environment the user's shell would give a program, for an app that was not started from one.
///
/// An app started at login gets `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and little else. Whatever it
/// starts inherits that, and so does what those start: Claude Code's background supervisor takes
/// the environment of whoever started it first and hands it to every session. Started by
/// Porchlight, sessions were left without Homebrew, Node or anything else the user installed
/// (seen 2026-10-09: the app had the four-folder path, a supervisor started from a terminal had
/// eleven). So the app asks the login shell once, at launch, and takes on what it answers.
///
/// The values are kept in memory only: never logged, never written to disk.
public enum ShellEnvironment {
    static let marker = "__PORCHLIGHT_ENVIRONMENT__"

    /// Variables that describe the shell that was asked, not the user's set-up.
    static let shellsOwn: Set<String> = ["SHLVL", "PWD", "OLDPWD", "_", "TERM", "TERM_PROGRAM", "TERM_SESSION_ID", "SHELL_SESSION_ID", "COLUMNS", "LINES"]

    /// What to run: a login, interactive shell, so both profile and rc files are read, printing
    /// its environment between two markers that set it apart from anything those files print.
    static func arguments() -> [String] {
        ["-l", "-i", "-c", "printf '%s' \(marker); /usr/bin/env -0; printf '%s' \(marker)"]
    }

    /// The variables between the markers. Nil when the output does not hold them.
    static func parse(_ output: String) -> [String: String]? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        var environment: [String: String] = [:]
        for entry in parts[parts.count - 2].split(separator: "\0") {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return environment.isEmpty ? nil : environment
    }

    /// Asks the shell. Nil when it cannot be asked or does not answer in time; the caller then
    /// keeps the environment it has.
    public static func resolve(shell: String, runner: CLIRunner = CLIRunner(), timeout: TimeInterval = 5) async -> [String: String]? {
        guard FileManager.default.isExecutableFile(atPath: shell),
              let result = try? await runner.run(URL(fileURLWithPath: shell), arguments(), timeout: timeout) else { return nil }
        return parse(result.stdout)
    }

    /// The same, waiting on the calling thread.
    static func resolveBlocking(shell: String, timeout: TimeInterval = 5) -> [String: String]? {
        guard FileManager.default.isExecutableFile(atPath: shell),
              let result = try? CLIRunner.runBlocking(URL(fileURLWithPath: shell), arguments(), cwd: nil, environment: nil, input: nil, timeout: timeout)
        else { return nil }
        return parse(result.stdout)
    }

    /// What the app's environment should become: the shell's variables over its own, except the
    /// ones that are only about that shell, and never an empty PATH.
    public static func merged(current: [String: String], shell: [String: String]) -> [String: String] {
        var merged = current
        for (name, value) in shell where !shellsOwn.contains(name) {
            merged[name] = value
        }
        if shell["PATH"]?.isEmpty != false { merged["PATH"] = current["PATH"] }
        return merged
    }

    /// The user's shell, as the system records it, else the environment's, else zsh.
    public static func loginShell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return environment["SHELL"] ?? "/bin/zsh"
    }

    /// Takes on the login shell's environment, so that everything this process starts gets it.
    /// Blocks until the shell has answered or the time is up. Returns whether anything changed.
    ///
    /// Not needed, and not done, when the process already has a terminal's environment.
    @discardableResult
    public static func adopt(
        current: [String: String] = ProcessInfo.processInfo.environment, shell: String? = nil, timeout: TimeInterval = 5,
        set: (String, String) -> Void = { setenv($0, $1, 1) }
    ) -> Bool {
        guard current["TERM_PROGRAM"] == nil, current["PORCHLIGHT_KEEP_ENVIRONMENT"] == nil else { return false }
        // Plainly blocking, with no task to wait for: parking a thread on a semaphore until a
        // task finishes hangs for good when every thread the tasks run on is parked the same
        // way, which is what happened on a three-core CI machine running tests side by side.
        guard let found = resolveBlocking(shell: shell ?? loginShell(environment: current), timeout: timeout) else { return false }
        var changed = false
        for (name, value) in merged(current: current, shell: found) where current[name] != value {
            set(name, value)
            changed = true
        }
        return changed
    }
}
