import Foundation

/// Which Porchlight this is, when it was installed with Homebrew.
///
/// The formula builds from the `main` branch, so there is no version number: the commit is the
/// version, and Homebrew writes it into the path it installs to. The app reads its own path to
/// know what it is, and asks git what `main` is now.
public enum AppVersion {
    /// Fully qualified, so an upgrade cannot hit a formula of the same name from elsewhere.
    public static let formula = "ksawerykarwacki/porchlight/porchlight"
    public static let repository = "https://github.com/ksawerykarwacki/porchlight.git"
    /// The names launchd may know the Homebrew service by: Homebrew's current one, and the one
    /// it used before. Asking for the old name alone found no service on a current Homebrew.
    public static let serviceLabels = ["sh.brew.porchlight", "homebrew.mxcl.porchlight"]

    /// The short commit in a Homebrew install path, or nil when the app was not installed by
    /// Homebrew. The path must have its symbolic links resolved first: `brew services` starts
    /// the app through `opt/porchlight`, a link, and only the real path names the commit.
    public static func installedCommit(bundlePath: String) -> String? {
        bundlePath.firstMatch(of: /\/Cellar\/porchlight\/HEAD-([0-9a-f]{7,40})\//).map { String($0.output.1) }
    }

    /// The commit `git ls-remote <repository> refs/heads/main` printed, or nil if that is not
    /// what the text is.
    public static func latestCommit(lsRemote: String) -> String? {
        guard let first = lsRemote.split(whereSeparator: \.isWhitespace).first, first.count == 40, first.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return String(first).lowercased()
    }

    /// Homebrew records a short commit and git prints the whole one.
    public static func isNewer(latest: String, installed: String) -> Bool {
        !installed.isEmpty && !latest.lowercased().hasPrefix(installed.lowercased())
    }

    /// Where Homebrew's own command is. A GUI app does not get the shell's PATH.
    public static func brew(isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: isExecutable)
    }
}

/// Checks for and installs updates of a Homebrew install. Every command is passed in, so tests
/// never touch Homebrew, git or the network.
public struct AppUpdater: Sendable {
    /// Runs a program with arguments and extra environment; returns its exit code and output.
    public typealias Run = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) async -> (status: Int32, output: String)

    public var run: Run
    public var brew: String?

    public init(brew: String? = AppVersion.brew(), run: @escaping Run = AppUpdater.liveRun) {
        self.brew = brew
        self.run = run
    }

    public enum Failure: Error, Equatable {
        case noHomebrew
        case failed(String)
    }

    /// The commit `main` is at now.
    public func latestCommit() async throws -> String {
        // Fail rather than hang on a credential prompt nobody can see.
        let result = await run("/usr/bin/git", ["ls-remote", AppVersion.repository, "refs/heads/main"], ["GIT_TERMINAL_PROMPT": "0"], 30)
        guard result.status == 0, let commit = AppVersion.latestCommit(lsRemote: result.output) else {
            throw Failure.failed(Self.lastLine(result.output) ?? "Could not ask what the latest version is.")
        }
        return commit
    }

    /// Rebuilds from the latest source. This compiles, so it takes minutes.
    public func upgrade() async throws {
        guard let brew else { throw Failure.noHomebrew }
        let result = await run(brew, ["upgrade", "--fetch-HEAD", AppVersion.formula], [:], 20 * 60)
        guard result.status == 0 else { throw Failure.failed(Self.tail(result.output)) }
    }

    static func lastLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).last.map { String($0).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The end of Homebrew's output, where it says what went wrong. When a command it ran in its
    /// sandbox fails, Homebrew prints the whole sandbox profile, one quoted line after another;
    /// those lines say nothing about the failure and are left out.
    static func tail(_ text: String, lines: Int = 6) -> String {
        let all = text.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            !line.hasPrefix("'") && !line.contains("sandbox-exec")
        }
        return all.suffix(lines).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static let liveRun: Run = { executable, arguments, environment, timeout in
        var merged = ProcessInfo.processInfo.environment
        // Homebrew and git need a PATH; a GUI app's is nearly empty.
        merged["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (key, value) in environment { merged[key] = value }
        do {
            let result = try await CLIRunner().run(URL(fileURLWithPath: executable), arguments, environment: merged, timeout: timeout)
            return (result.exitCode, result.stdout + result.stderr)
        } catch {
            return (-1, "\(error)")
        }
    }
}

/// The end of a failed command's output, for the command line.
public enum AppUpdaterText {
    public static func tail(_ text: String) -> String {
        let end = AppUpdater.tail(text)
        return end.isEmpty ? "no output" : end
    }
}
