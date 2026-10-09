import AppKit
import Foundation
import PorchlightCore

/// The terminals Porchlight can drive. Each was seen running a command before being listed here.
public enum TerminalApp: String, CaseIterable, Sendable {
    case warp
    case ghostty
    case wezterm
    case terminal

    public var bundleName: String {
        switch self {
        case .warp: "Warp.app"
        case .ghostty: "Ghostty.app"
        case .wezterm: "WezTerm.app"
        case .terminal: "Terminal.app"
        }
    }

    public var displayName: String { String(bundleName.dropLast(4)) }

    /// Whether the command opens as a tab in the current window rather than a new window.
    public var opensTab: Bool { self == .warp }

    /// Ghostty asks "Allow Ghostty to execute …?" every time it is started with a command. That
    /// is a deliberate safeguard of theirs with no setting to turn it off, so the user confirms
    /// once per open. Because of it, this adapter could not be checked unattended.
    public var asksBeforeRunning: Bool { self == .ghostty }

    public func installedPath(home: String = NSHomeDirectory(), exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        ["/Applications", "\(home)/Applications", "/System/Applications/Utilities"]
            .map { "\($0)/\(bundleName)" }
            .first(where: exists)
    }

    /// The terminal to use when the user has not chosen: one that is running now, else the first
    /// one installed. Terminal.app ships with macOS, so there is always an answer in practice.
    public static func detect(running: [String], installed: (TerminalApp) -> Bool) -> TerminalApp? {
        let available = allCases.filter(installed)
        return available.first { running.contains($0.bundleName) } ?? available.first
    }
}

/// One thing the launcher does. Plans are data, so they can be tested without opening windows.
public enum LaunchStep: Sendable, Equatable {
    case run(executable: String, arguments: [String], input: String? = nil)
    case write(path: String, contents: String, executable: Bool = false)
}

public enum TerminalPlanner {
    /// The steps that make `app` run `command`.
    ///
    /// The command is wrapped in the user's login shell so it runs with their PATH and
    /// environment, which a terminal started by a GUI app would not otherwise have. The shell
    /// line changes directory itself as well: a terminal that ignores its working-directory option
    /// would start `claude` in the home folder, where it stops to ask whether to trust the folder.
    public static func plan(for app: TerminalApp, appPath: String, command: TerminalCommand, shell: String, home: String, scratch: String) -> [LaunchStep] {
        let cwd = command.cwd ?? home
        let wrapped = [shell, "-l", "-i", "-c", "cd \(ShellQuote.quote(cwd)) && exec " + ShellQuote.line(command.arguments)]
        switch app {
        case .ghostty:
            return [.run(executable: "/usr/bin/open", arguments: ["-na", appPath, "--args", "--working-directory=\(cwd)", "-e"] + wrapped)]
        case .wezterm:
            return [.run(executable: "/usr/bin/open", arguments: ["-na", appPath, "--args", "start", "--cwd", cwd, "--"] + wrapped)]
        case .terminal:
            // A .command file is opened by Terminal without AppleScript, so no Automation prompt.
            let script = "\(scratch)/porchlight-open.command"
            let body = "#!/bin/sh\ncd \(ShellQuote.quote(cwd)) || exit 1\nexec \(ShellQuote.line(wrapped))\n"
            return [
                .write(path: script, contents: body, executable: true),
                .run(executable: "/usr/bin/open", arguments: ["-a", appPath, script]),
            ]
        case .warp:
            // Warp's URI scheme cannot carry a command; a saved tab config can. Porchlight keeps
            // exactly one, rewritten on each open, which also shows up in Warp's "+" menu.
            let config = """
                name = "Porchlight"
                title = \(toml(command.title))

                [[panes]]
                id = "main"
                type = "terminal"
                directory = \(toml(cwd))
                commands = [\(toml("cd \(ShellQuote.quote(cwd)) && " + ShellQuote.line(command.arguments)))]

                """
            return [
                .write(path: "\(home)/.warp/tab_configs/porchlight.toml", contents: config),
                .run(executable: "/usr/bin/open", arguments: ["warp://tab_config/porchlight"]),
            ]
        }
    }

    /// The floor every adapter falls back to: the command on the clipboard.
    public static func clipboardPlan(command: TerminalCommand) -> [LaunchStep] {
        [.run(executable: "/usr/bin/pbcopy", arguments: [], input: command.shellLine)]
    }

    /// A TOML basic string.
    static func toml(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// Opens commands in the user's terminal, falling back to the clipboard when that fails.
public struct MacTerminalLauncher: TerminalLauncher {
    /// The user's choice. Nil detects one.
    public var preferred: TerminalApp?
    /// Switch to an agent view that is already open rather than attach in a new tab.
    public var preferAgentView = false
    /// Where a running `porchlight tab` listens for sessions to show.
    public var tabChannel = TabChannel()
    public var runner = CLIRunner()
    /// Brings the app at a path to the front with the keyboard. Replaceable in tests.
    public var activate: @Sendable (String) async -> Void = MacTerminalLauncher.activateApp
    public var home = NSHomeDirectory()
    public var scratch = PorchlightPaths.stateDirectory().appendingPathComponent("run").path

    public init(preferred: TerminalApp? = nil) {
        self.preferred = preferred
    }

    public init(settings: Settings) {
        self.preferred = settings.terminal.flatMap { TerminalApp(rawValue: $0.lowercased()) }
        self.preferAgentView = settings.preferAgentView ?? false
    }

    public func resolveTerminal() async -> (app: TerminalApp, path: String)? {
        if let preferred, let path = preferred.installedPath(home: home) { return (preferred, path) }
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.lastPathComponent }
        }
        guard let app = TerminalApp.detect(running: running, installed: { $0.installedPath(home: home) != nil }),
              let path = app.installedPath(home: home)
        else { return nil }
        return (app, path)
    }

    public func open(_ command: TerminalCommand) async -> LaunchOutcome {
        if let sessionID = command.sessionID {
            let processes = await processTable()
            // Bringing the app forward is all that can be done everywhere: none of these
            // terminals lets another program select one particular tab.
            if let existing = installed(processes?.terminalAttached(to: sessionID)) {
                await bringForward(existing.path)
                return .alreadyOpen(terminal: existing.app.displayName)
            }
            // A `porchlight tab` is the one place a click can land exactly: it swaps that tab
            // to the session, so nothing new is opened.
            if let host = tabChannel.liveHost(), await tabChannel.requestAndWait(sessionID: sessionID) {
                let terminal = installed(processes?.terminal(owning: host.pid))
                if let terminal { await bringForward(terminal.path) }
                return .switchedInTab(terminal: terminal?.app.displayName)
            }
            if preferAgentView, let existing = installed(processes?.terminalRunningAgentView()) {
                await bringForward(existing.path)
                return .agentViewFocused(terminal: existing.app.displayName)
            }
        }
        if command.opensAgentView, let existing = installed(await processTable()?.terminalRunningAgentView()) {
            // Agent view is already open somewhere: go there rather than start a second one.
            await bringForward(existing.path)
            return .agentViewFocused(terminal: existing.app.displayName)
        }
        guard let terminal = await resolveTerminal() else {
            return await copy(command, reason: "no supported terminal is installed")
        }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let steps = TerminalPlanner.plan(for: terminal.app, appPath: terminal.path, command: command, shell: shell, home: home, scratch: scratch)
        do {
            try await execute(steps)
            await activate(terminal.path)
            return .opened(terminal: terminal.app.displayName)
        } catch {
            return await copy(command, reason: "\(terminal.app.displayName) could not be opened")
        }
    }

    /// Opens the app (which also un-hides and un-minimises it) and then hands it the keyboard.
    /// Opening alone is not enough when the terminal was already the front app: macOS then has
    /// nothing to do, and the keyboard stays with whoever took it last, which was Porchlight's
    /// own panel.
    func bringForward(_ path: String) async {
        _ = try? await runner.run(URL(fileURLWithPath: "/usr/bin/open"), ["-a", path])
        await activate(path)
    }

    @MainActor
    static func runningApp(atPath path: String) -> NSRunningApplication? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL.path == wanted }
    }

    /// Makes the running app at `path` the active one, giving up this app's own claim first.
    @MainActor
    public static func activateApp(atPath path: String) {
        guard let app = runningApp(atPath: path) else { return }
        // Since macOS 14 an app is only activated over the active one if that one yields to it.
        NSApp?.yieldActivation(to: app)
        app.activate(options: [.activateAllWindows])
    }

    /// What the last hand-over did, for the activity log.
    @MainActor public private(set) static var lastHandOver = "none"

    /// Hands the keyboard to the app at `path`. When that app is already the front one, asking
    /// macOS to activate it does nothing, and a terminal that lost the keyboard to the menu-bar
    /// panel is never told it has it back (seen with Warp, 2026-10-09: front app Warp, Porchlight
    /// inactive, panel closed, and typing went nowhere). So Porchlight first becomes the active
    /// app for a moment, which makes the hand-over a real change that the terminal reacts to.
    public static let activateApp: @Sendable (String) async -> Void = { path in
        let wasFront = await MainActor.run { () -> Bool in
            guard let app = runningApp(atPath: path), NSApp != nil else { return false }
            guard NSWorkspace.shared.frontmostApplication == app else { return false }
            FocusBounce.take()
            return true
        }
        if wasFront {
            try? await Task.sleep(for: .milliseconds(180))
        }
        await MainActor.run {
            let between = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
            FocusBounce.release()
            activateApp(atPath: path)
            lastHandOver = wasFront ? "bounced through Porchlight (front in between: \(between))" : "activated directly"
        }
    }

    func processTable() async -> ProcessTable? {
        guard let listing = try? await runner.run(URL(fileURLWithPath: "/bin/ps"), ["-axo", "pid=,ppid=,command="]),
              listing.succeeded
        else { return nil }
        return ProcessTable(psOutput: listing.stdout)
    }

    private func installed(_ app: TerminalApp?) -> (app: TerminalApp, path: String)? {
        guard let app, let path = app.installedPath(home: home) else { return nil }
        return (app, path)
    }

    private func copy(_ command: TerminalCommand, reason: String) async -> LaunchOutcome {
        do {
            try await execute(TerminalPlanner.clipboardPlan(command: command))
            return .copiedToClipboard(reason: reason)
        } catch {
            return .failed("\(reason), and the command could not be copied either")
        }
    }

    struct StepFailed: Error {}

    func execute(_ steps: [LaunchStep]) async throws {
        for step in steps {
            switch step {
            case .write(let path, let contents, let executable):
                let url = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contents.utf8).write(to: url, options: .atomic)
                if executable {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
                }
            case .run(let executable, let arguments, let input):
                let result = try await runner.run(URL(fileURLWithPath: executable), arguments, input: input, timeout: 20)
                guard result.succeeded else { throw StepFailed() }
            }
        }
    }
}

/// A snapshot of running processes, enough to tell which terminal a process lives in.
struct ProcessTable {
    struct Entry {
        let parent: Int32
        let command: String
    }

    let entries: [Int32: Entry]

    /// Parses `ps -axo pid=,ppid=,command=`.
    init(psOutput: String) {
        var entries: [Int32: Entry] = [:]
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            entries[pid] = Entry(parent: parent, command: String(fields[2]))
        }
        self.entries = entries
    }

    /// The terminal that an existing `claude attach <sessionID>` descends from.
    func terminalAttached(to sessionID: String) -> TerminalApp? {
        for (pid, entry) in entries.sorted(by: { $0.key < $1.key }) where Self.isAttach(entry.command, to: sessionID) {
            if let app = terminal(owning: pid) { return app }
        }
        return nil
    }

    /// The terminal an interactive agent view (`claude agents`) is running in.
    func terminalRunningAgentView() -> TerminalApp? {
        for (pid, entry) in entries.sorted(by: { $0.key < $1.key }) where Self.isAgentView(entry.command) {
            if let app = terminal(owning: pid) { return app }
        }
        return nil
    }

    /// True for `claude agents` with no `--json`, which only prints and exits.
    static func isAgentView(_ command: String) -> Bool {
        let words = command.split(separator: " ")
        guard words.count >= 2, words[1] == "agents", !words.contains("--json") else { return false }
        return words[0] == "claude" || words[0].hasSuffix("/claude")
    }

    /// True for `…/claude attach <id>`, and not for a shell line that merely mentions it.
    static func isAttach(_ command: String, to sessionID: String) -> Bool {
        let words = command.split(separator: " ")
        guard words.count >= 3, words[1] == "attach", words[2] == sessionID else { return false }
        return words[0] == "claude" || words[0].hasSuffix("/claude")
    }

    func terminal(owning pid: Int32) -> TerminalApp? {
        var current = pid
        // A bounded walk: a process table read mid-change can contain a cycle.
        for _ in 0..<32 {
            guard let entry = entries[current] else { return nil }
            if let app = TerminalApp.allCases.first(where: { entry.command.contains("/\($0.bundleName)/") }) {
                return app
            }
            guard entry.parent > 1 else { return nil }
            current = entry.parent
        }
        return nil
    }
}

/// Lets Porchlight become the active app for a moment without showing anything.
@MainActor
enum FocusBounce {
    private static var window: NSWindow?

    static func take() {
        let window = self.window ?? {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.level = .floating
            return window
        }()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
    }

    static func release() {
        window?.orderOut(nil)
    }
}
