import Foundation
import PorchlightCore
import Testing

@testable import PorchlightMac

@Suite struct TerminalLauncherTests {
    let command = TerminalCommand(
        arguments: ["/Users/u/.local/bin/claude", "attach", "4cb41c2a"], cwd: "/Users/u/code/my repo", title: "fix \"flaky\" test")

    func plan(_ app: TerminalApp) -> [LaunchStep] {
        TerminalPlanner.plan(
            for: app, appPath: "/Applications/\(app.bundleName)", command: command,
            shell: "/bin/zsh", home: "/Users/u", scratch: "/Users/u/Library/Application Support/Porchlight/run")
    }

    let wrapped = ["/bin/zsh", "-l", "-i", "-c", "cd '/Users/u/code/my repo' && exec /Users/u/.local/bin/claude attach 4cb41c2a"]

    @Test func ghosttyGetsTheCommandAsArgumentsAfterDashE() {
        #expect(plan(.ghostty) == [
            .run(executable: "/usr/bin/open", arguments: ["-na", "/Applications/Ghostty.app", "--args", "--working-directory=/Users/u/code/my repo", "-e"] + wrapped)
        ])
    }

    @Test func wezTermGetsStartWithAWorkingDirectory() {
        #expect(plan(.wezterm) == [
            .run(executable: "/usr/bin/open", arguments: ["-na", "/Applications/WezTerm.app", "--args", "start", "--cwd", "/Users/u/code/my repo", "--"] + wrapped)
        ])
    }

    @Test func terminalAppGetsAnExecutableCommandFile() {
        let script = "/Users/u/Library/Application Support/Porchlight/run/porchlight-open.command"
        #expect(plan(.terminal) == [
            .write(path: script, contents: "#!/bin/sh\ncd '/Users/u/code/my repo' || exit 1\nexec /bin/zsh -l -i -c 'cd '\\''/Users/u/code/my repo'\\'' && exec /Users/u/.local/bin/claude attach 4cb41c2a'\n", executable: true),
            .run(executable: "/usr/bin/open", arguments: ["-a", "/Applications/Terminal.app", script]),
        ])
    }

    @Test func warpGetsATabConfigAndItsURI() {
        let steps = plan(.warp)
        #expect(steps.count == 2)
        guard case .write(let path, let contents, let executable) = steps[0] else {
            Issue.record("expected a file write first")
            return
        }
        #expect(path == "/Users/u/.warp/tab_configs/porchlight.toml")
        #expect(!executable)
        #expect(contents.contains(#"title = "fix \"flaky\" test""#))
        #expect(contents.contains(#"directory = "/Users/u/code/my repo""#))
        #expect(contents.contains(#"commands = ["cd '/Users/u/code/my repo' && /Users/u/.local/bin/claude attach 4cb41c2a"]"#))
        #expect(steps[1] == .run(executable: "/usr/bin/open", arguments: ["warp://tab_config/porchlight"]))
    }

    @Test func quotesHostileTextForShellAndTOML() {
        #expect(ShellQuote.quote("plain-arg_1.0") == "plain-arg_1.0")
        #expect(ShellQuote.quote("") == "''")
        #expect(ShellQuote.quote("it's; rm -rf $HOME") == #"'it'\''s; rm -rf $HOME'"#)
        #expect(TerminalPlanner.toml("a\"b\\c\nd\u{01}") == #""a\"b\\c\nd\u0001""#)
        let hostile = TerminalCommand(arguments: ["claude", "attach", "x; touch /tmp/pwned"], cwd: "/tmp/a b", title: "t")
        #expect(hostile.shellLine == "cd '/tmp/a b' && claude attach 'x; touch /tmp/pwned'")
    }

    @Test func theClipboardFallbackCopiesWhatAPersonWouldType() {
        #expect(TerminalPlanner.clipboardPlan(command: command) == [
            .run(executable: "/usr/bin/pbcopy", arguments: [], input: "cd '/Users/u/code/my repo' && /Users/u/.local/bin/claude attach 4cb41c2a")
        ])
    }

    @Test func prefersARunningTerminalThenAnyInstalledOne() {
        let all: (TerminalApp) -> Bool = { _ in true }
        #expect(TerminalApp.detect(running: ["Finder.app", "Ghostty.app"], installed: all) == .ghostty)
        #expect(TerminalApp.detect(running: ["Ghostty.app", "Warp.app"], installed: all) == .warp)
        #expect(TerminalApp.detect(running: ["Warp.app"], installed: { $0 != .warp }) == .ghostty)
        #expect(TerminalApp.detect(running: [], installed: { $0 == .terminal }) == .terminal)
        #expect(TerminalApp.detect(running: [], installed: { _ in false }) == nil)
        #expect(TerminalApp.wezterm.installedPath(home: "/Users/u", exists: { $0 == "/Users/u/Applications/WezTerm.app" }) == "/Users/u/Applications/WezTerm.app")
    }

    @Test func buildsAttachAndAgentViewCommands() {
        let session = Session(summary: SessionSummary(id: "55555555", name: "probe", cwd: "/Users/u/code/probe/.claude/worktrees/add-hello", state: .blocked))
        let attach = TerminalCommand.attach(to: session, claude: "/opt/homebrew/bin/claude")
        #expect(attach.arguments == ["/opt/homebrew/bin/claude", "attach", "55555555"])
        #expect(attach.cwd == "/Users/u/code/probe")
        #expect(attach.title == "probe")
        #expect(attach.sessionID == "55555555")
        #expect(!attach.opensAgentView)
        #expect(TerminalCommand.agentView(claude: "claude").opensAgentView)
        #expect(TerminalCommand.agentView(claude: "claude").sessionID == nil)
        #expect(TerminalCommand.agentView(claude: "claude").shellLine == "claude agents")
        #expect(TerminalCommand.agentView(claude: "claude", cwd: "/Users/u/code/probe").shellLine == "cd /Users/u/code/probe && claude agents")
    }

    @Test func startsAgentViewWhereTheMostRecentSessionLives() {
        func session(_ id: String, _ cwd: String, started: TimeInterval) -> Session {
            Session(summary: SessionSummary(id: id, name: id, cwd: cwd, state: .done, startedAt: Date(timeIntervalSince1970: started)))
        }
        let sessions = [
            session("old", "/Users/u/code/old", started: 100),
            session("new", "/Users/u/code/new/.claude/worktrees/w", started: 300),
            session("mid", "/Users/u/code/mid", started: 200),
        ]
        #expect(TerminalCommand.trustedDirectory(among: sessions) == "/Users/u/code/new")
        #expect(TerminalCommand.trustedDirectory(among: []) == nil)
    }

    @Test func findsTheTerminalASessionIsAlreadyAttachedIn() {
        let table = ProcessTable(psOutput: """
              1     0 /sbin/launchd
            500     1 /Applications/Warp.app/Contents/MacOS/stable
            510   500 /Applications/Warp.app/Contents/MacOS/stable terminal-server --parent-pid=500
            520   510 -zsh -g --no_rcs
            530   520 /Users/u/.local/bin/claude attach 4cb41c2a
            600     1 /Applications/Ghostty.app/Contents/MacOS/ghostty
            610   600 /usr/bin/login -flp u /bin/zsh
            620   610 -zsh
            630   620 claude attach 99999999
            700     1 /bin/zsh -c echo claude attach 77777777
            710   700 /Users/u/.local/bin/claude attach 88888888
            """)
        #expect(table.terminalAttached(to: "4cb41c2a") == .warp)
        #expect(table.terminalAttached(to: "99999999") == .ghostty)
        // Attached, but not inside a terminal Porchlight knows.
        #expect(table.terminalAttached(to: "88888888") == nil)
        // A shell line that only mentions the command is not an attach.
        #expect(table.terminalAttached(to: "77777777") == nil)
        #expect(table.terminalAttached(to: "nope") == nil)
        #expect(!ProcessTable.isAttach("/x/claude attach 4cb41c2a9", to: "4cb41c2a"))
        #expect(!ProcessTable.isAttach("/x/notclaude attach 4cb41c2a", to: "4cb41c2a"))
    }

    @Test func findsTheTerminalAgentViewIsOpenIn() {
        let open = ProcessTable(psOutput: """
            500     1 /Applications/Warp.app/Contents/MacOS/stable
            520   500 -zsh -g --no_rcs
            530   520 claude agents
            """)
        #expect(open.terminalRunningAgentView() == .warp)

        let notOpen = ProcessTable(psOutput: """
            500     1 /Applications/Warp.app/Contents/MacOS/stable
            520   500 -zsh -g --no_rcs
            530   520 /Users/u/.local/bin/claude agents --json --all
            540   520 /Users/u/.local/bin/claude attach 4cb41c2a
            600     1 /usr/libexec/daemon
            610   600 claude agents
            """)
        // A one-shot --json listing and an agent view outside any known terminal do not count.
        #expect(notOpen.terminalRunningAgentView() == nil)
        #expect(ProcessTable.isAgentView("/opt/homebrew/bin/claude agents --cwd /x"))
        #expect(!ProcessTable.isAgentView("claude attach agents"))
    }

    @Test func remembersThePreferenceForAgentView() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-prefer-\(UUID().uuidString)")
        let url = Settings.fileURL(in: directory)
        #expect(MacTerminalLauncher(settings: Settings.load(from: url)).preferAgentView == false)
        try Settings(terminal: "ghostty", preferAgentView: true).save(to: url)
        let launcher = MacTerminalLauncher(settings: Settings.load(from: url))
        #expect(launcher.preferAgentView)
        #expect(launcher.preferred == .ghostty)
    }

    @Test func settingsSurviveARoundTripAndTolerateBrokenFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-settings-\(UUID().uuidString)")
        let url = Settings.fileURL(in: directory)
        #expect(Settings.load(from: url) == Settings())
        try Settings(terminal: "Warp", claudePath: nil).save(to: url)
        #expect(Settings.load(from: url).terminal == "Warp")
        #expect(MacTerminalLauncher(settings: Settings.load(from: url)).preferred == .warp)
        try Data(#"{"terminal": 7, "future": true}"#.utf8).write(to: url)
        #expect(Settings.load(from: url) == Settings())
    }

    @Test func fallsBackToTheClipboardWhenAStepFails() async throws {
        var launcher = MacTerminalLauncher(preferred: .terminal)
        // A scratch path that cannot be created makes the .command write fail.
        launcher.scratch = "/dev/null/porchlight"
        let marker = "porchlight-clipboard-test-\(UUID().uuidString)"
        let before = try await CLIRunner().run(URL(fileURLWithPath: "/usr/bin/pbpaste"), []).stdout
        defer { _ = Task { try? await CLIRunner().run(URL(fileURLWithPath: "/usr/bin/pbcopy"), [], input: before) } }

        let outcome = await launcher.open(TerminalCommand(arguments: ["echo", marker], title: "t"))
        #expect(outcome == .copiedToClipboard(reason: "Terminal could not be opened"))
        #expect(try await CLIRunner().run(URL(fileURLWithPath: "/usr/bin/pbpaste"), []).stdout == "echo \(marker)")
    }
}

/// Opens real terminal windows, so it only runs when asked:
///   PORCHLIGHT_LIVE_TERMINALS=warp,ghostty swift test --filter LiveTerminalTests
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PORCHLIGHT_LIVE_TERMINALS"] != nil))
struct LiveTerminalTests {
    @Test func eachRequestedTerminalRunsTheCommand() async throws {
        let requested = (ProcessInfo.processInfo.environment["PORCHLIGHT_LIVE_TERMINALS"] ?? "")
            .split(separator: ",").compactMap { TerminalApp(rawValue: String($0)) }
        #expect(!requested.isEmpty)
        for app in requested {
            let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("porchlight live \(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // A relative marker proves both that the command ran and that it ran in the directory.
            let command = TerminalCommand(arguments: ["/usr/bin/touch", "ran here"], cwd: directory.path, title: "Porchlight live test")
            let outcome = await MacTerminalLauncher(preferred: app).open(command)
            #expect(outcome == .opened(terminal: app.displayName))

            let marker = directory.appendingPathComponent("ran here").path
            let deadline = ContinuousClock.now + .seconds(30)
            while !FileManager.default.fileExists(atPath: marker), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
            #expect(FileManager.default.fileExists(atPath: marker), "\(app.displayName) did not run the command")
        }
    }
}
