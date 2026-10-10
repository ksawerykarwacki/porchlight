import Foundation
import PorchlightCore

#if canImport(PorchlightMac)
import PorchlightMac
#endif

let usage = """
    porchlight — see which Claude Code background sessions are waiting on you

    Usage:
      porchlight status [--json] [--active]   List sessions (--active leaves out finished ones)
      porchlight watch [--once]               Print one JSON line now and one after every change
      porchlight open <id> [--terminal NAME]  Attach to a session in your terminal (macOS)
      porchlight open --agents                Open agent view in your terminal (macOS)
      porchlight terminal [NAME|auto]         Show or set the terminal sessions open in (macOS)
      porchlight snooze <id> 1h|4h|tomorrow|change|off
                                              Pause reminders for a session: for a while, until
                                              tomorrow 09:00, until it asks something new, or not
      porchlight repos [--json] [TEXT]        List the repositories sessions can start in, or the
                                              ones matching TEXT
      porchlight repos root add|remove DIR    Choose the folders that are searched for repositories
      porchlight repos pin|unpin DIR          Keep a repository at the top of the list
      porchlight new                          Show the app's palette for starting a session (macOS)
      porchlight dispatch [--dir DIR | --repo TEXT] [--open] PROMPT
                                              Start a background session in a folder (default: this
                                              one), named from the prompt. More options: --name,
                                              --no-name, --model, --effort, --agent,
                                              --permission-mode, --worktree[=NAME], --json
      porchlight name [--dir DIR] PROMPT      Print the name a session started with PROMPT would get
      porchlight triage [--json]              List sessions that are finished, stopped or long waiting,
                                              each with a verdict: safe to remove, needs a decision,
                                              stale, or keep
      porchlight wrap-up <id> [--on-device | --claude] [--model MODEL] [--json]
                                              Summarise a session and keep the summary as a note.
                                              On this Mac (the default where Apple's on-device model
                                              is available): free, reads the first request and the
                                              end. With Claude: reads all of it as a copy with every
                                              tool off, and uses Claude usage. The session is not
                                              changed either way
      porchlight notes [--json] [TEXT]        Show the notes kept so far, or the ones containing TEXT
      porchlight pin <id> [--quiet]           Keep a session: it is grouped at the top and never
                                              offered for removal; --quiet also turns its reminders off
      porchlight unpin <id>
      porchlight stop <id>                    Stop a background session; its conversation is kept
      porchlight rm <id>                      Remove a background session. If Claude Code refuses, for
                                              example because of unpushed commits, its reason is printed
                                              and nothing is forced
      porchlight settings                     Print the settings in force, as JSON
      porchlight settings export [FILE]       Write the settings file (to FILE, or print it)
      porchlight settings import FILE         Replace the settings with those in FILE
      porchlight tab                          Run agent view in this tab and let the app switch it
                                              to a session when you click one
      porchlight companion                    Listen for the companion mod in place of the app and
                                              print what sessions report, until interrupted. For
                                              checking the mod; refuses while the app is listening
      porchlight doctor                       Check that the claude CLI can be found and used
      porchlight help

    Environment:
      PORCHLIGHT_CLAUDE   Path to the claude executable, overriding the search
      PORCHLIGHT_FM       Path to Apple's fm tool, instead of /usr/bin/fm
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

/// Where `claude` is looked for by every command: the PORCHLIGHT_CLAUDE variable, else the path
/// in the settings, else the usual places.
func claudeLocator() -> ClaudeLocator {
    ClaudeLocator(override: ProcessInfo.processInfo.environment["PORCHLIGHT_CLAUDE"] ?? Settings.load().claudePath)
}

/// The sessions, read through that same `claude`.
func liveStore() -> SessionStore {
    SessionStore.live(locator: claudeLocator())
}

func locateClaude() -> URL {
    let locator = ClaudeLocator(override: ProcessInfo.processInfo.environment["PORCHLIGHT_CLAUDE"])
    guard let url = locator.locate() else {
        fail("claude not found. Looked in:\n" + locator.candidates().map { "  \($0)" }.joined(separator: "\n"))
    }
    return url
}

func status(arguments: [String]) async {
    let store = liveStore()
    await store.refresh()
    let snapshot = await store.snapshot
    if let problem = snapshot.problem {
        fail(describe(problem))
    }
    var sessions = snapshot.sessions
    if arguments.contains("--active") {
        sessions.removeAll { $0.summary.state == .done }
    }

    if arguments.contains("--json") {
        do {
            print(try StatusReport(sessions: sessions, skippedRows: snapshot.skippedRows, snoozes: ReminderState.load().snoozes, pins: Pins.load()).json())
        } catch {
            fail("could not encode status: \(error)")
        }
        return
    }

    let groups = InboxGroups(sessions: sessions)
    print("\(groups.needsYou.count) waiting on you, \(sessions.count) sessions in total")
    for (title, group) in [("Needs you", groups.needsYou), ("Working", groups.working), ("Recently done", groups.recentlyDone), ("Other", groups.other)] where !group.isEmpty {
        print("\n\(title)")
        for session in group {
            let location = session.location
            let place = location.worktreeName.map { "\(location.repoName) (\($0))" } ?? location.repoName
            let waited = Age.short(since: session.waitingSince).map { "  waiting \($0)" } ?? ""
            print("  \(session.id)  \(session.name)  [\(place)]\(waited)")
            switch session.needs {
            case .question(let text): print("      asks: \(text)")
            case .approval(let tool, let detail): print("      wants approval for \(tool): \(detail)")
            case .other(let text): print("      needs: \(text)")
            case nil: break
            }
        }
    }
}

/// Prints the current status as one JSON line, then one more line whenever something changes.
func watch(arguments: [String]) async {
    let store = liveStore()
    let updates = await store.updates()
    let once = arguments.contains("--once")
    let loop = Task { await RefreshLoop().run(store: store, triggers: once ? [] : [PollingChangeWatcher()]) }
    defer { loop.cancel() }

    var isFirst = true
    for await update in updates {
        // After the first line, only speak when something changed or freshness flipped.
        guard isFirst || !update.events.isEmpty || update.snapshot.isStale != lastStale else { continue }
        lastStale = update.snapshot.isStale
        do {
            print(try WatchLine(update: update, isFirst: isFirst).json())
            fflush(stdout)
        } catch {
            fail("could not encode status: \(error)")
        }
        isFirst = false
        if once { return }
    }
}

nonisolated(unsafe) var lastStale = false

/// Runs `claude attach <id>` (or agent view) in the user's terminal.
func open(arguments: [String]) async {
    #if canImport(PorchlightMac)
    let settings = Settings.load()
    let locator = ClaudeLocator(override: ProcessInfo.processInfo.environment["PORCHLIGHT_CLAUDE"] ?? settings.claudePath)
    guard let claude = locator.locate() else {
        fail(describe(.claudeNotFound(candidates: locator.candidates())))
    }

    var launcher = MacTerminalLauncher(settings: settings)
    if let flag = arguments.firstIndex(of: "--terminal") {
        guard arguments.indices.contains(flag + 1), let app = TerminalApp(rawValue: arguments[flag + 1].lowercased()) else {
            fail("--terminal takes one of: " + TerminalApp.allCases.map(\.rawValue).joined(separator: ", "), code: 2)
        }
        launcher.preferred = app
    }

    let command: TerminalCommand
    if arguments.contains("--agents") {
        command = .agentView(claude: claude.path, cwd: FileManager.default.currentDirectoryPath)
    } else {
        guard let id = arguments.first, !id.hasPrefix("--") else { fail("open needs a session id, or --agents", code: 2) }
        let store = SessionStore.live(locator: locator)
        await store.refresh()
        let snapshot = await store.snapshot
        if let problem = snapshot.problem { fail(describe(problem)) }
        // Like `claude attach`, accept the id or part of the name, but only when it is unambiguous.
        var matches = snapshot.sessions.filter { $0.id == id }
        if matches.isEmpty {
            matches = snapshot.sessions.filter { $0.name.localizedCaseInsensitiveContains(id) }
        }
        guard matches.count == 1, let session = matches.first else {
            fail(matches.isEmpty ? "no session matches \(id)" : "\(matches.count) sessions match \(id); use the id")
        }
        command = .attach(to: session, claude: claude.path)
    }

    switch await launcher.open(command) {
    case .opened(let terminal): print("opened in \(terminal)")
    case .alreadyOpen(let terminal): print("already open in \(terminal); brought it to the front")
    case .switchedInTab(let terminal): print("switched your porchlight tab to it" + (terminal.map { " in \($0)" } ?? ""))
    case .agentViewFocused(let terminal):
        print("agent view is already open in \(terminal); brought it to the front" + (command.opensAgentView ? "" : ", pick the session there"))
    case .copiedToClipboard(let reason): print("\(reason); the command is on your clipboard:\n  \(command.shellLine)")
    case .failed(let reason): fail(reason)
    }
    #else
    fail("open is only available on macOS")
    #endif
}

/// Shows or sets which terminal `open` and the app use.
func terminal(arguments: [String]) {
    #if canImport(PorchlightMac)
    var settings = Settings.load()
    let names = TerminalApp.allCases.map(\.rawValue)
    guard let choice = arguments.first?.lowercased() else {
        print("terminal: \(settings.terminal ?? "auto (whichever is running)")")
        let installed = TerminalApp.allCases.filter { $0.installedPath() != nil }.map(\.rawValue)
        print("installed: \(installed.joined(separator: ", "))")
        return
    }
    if choice == "auto" {
        settings.terminal = nil
    } else if let app = TerminalApp(rawValue: choice) {
        guard app.installedPath() != nil else { fail("\(app.displayName) is not installed") }
        settings.terminal = app.rawValue
    } else {
        fail("terminal takes one of: auto, " + names.joined(separator: ", "), code: 2)
    }
    do {
        try settings.save()
    } catch {
        fail("could not save settings: \(error)")
    }
    print("terminal: \(settings.terminal ?? "auto (whichever is running)")")
    #else
    fail("terminal is only available on macOS")
    #endif
}

/// Hosts agent view in this terminal tab and swaps it to whichever session the app asks for.
func tab() -> Never {
    let settings = Settings.load()
    let locator = ClaudeLocator(override: ProcessInfo.processInfo.environment["PORCHLIGHT_CLAUDE"] ?? settings.claudePath)
    guard let claude = locator.locate() else {
        fail(describe(.claudeNotFound(candidates: locator.candidates())))
    }
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
        fail("porchlight tab needs a terminal: run it in the tab you want to keep agent view in")
    }
    let channel = TabChannel()
    if let other = channel.liveHost(), other.pid != ProcessInfo.processInfo.processIdentifier {
        fail("another porchlight tab is already running (pid \(other.pid)); close that one first")
    }
    do {
        exit(try TabHost(channel: channel, commands: .claude(claude.path)).run())
    } catch {
        fail("could not start: \(error)")
    }
}

/// Pauses or resumes reminders for one session.
func snooze(arguments: [String]) async {
    guard arguments.count == 2 else { fail("usage: porchlight snooze <id> 1h|4h|tomorrow|change|off", code: 2) }
    let store = liveStore()
    await store.refresh()
    let snapshot = await store.snapshot
    if let problem = snapshot.problem { fail(describe(problem)) }
    guard let session = snapshot.sessions.first(where: { $0.id == arguments[0] }) else {
        fail("no session with id \(arguments[0])")
    }
    guard session.needsHuman else { fail("\(session.name) is not waiting on you, so there is nothing to snooze") }

    var state = ReminderState.load()
    let now = Date()
    let choice = arguments[1].lowercased()
    if choice == "off" {
        state.clearSnooze(session.id)
    } else if choice == "tomorrow" {
        state.snooze(session.id, .tomorrow(after: now, calendar: .current))
    } else if choice == "change" {
        guard let since = session.waitingSince else { fail("cannot tell when \(session.name) started waiting") }
        state.snooze(session.id, .untilChange(waitingSince: since))
    } else if choice.hasSuffix("h"), let hours = Double(choice.dropLast()), hours > 0, hours <= 24 * 30 {
        state.snooze(session.id, .until(now.addingTimeInterval(hours * 3600)))
    } else if choice.hasSuffix("m"), let minutes = Double(choice.dropLast()), minutes > 0, minutes <= 60 * 24 {
        state.snooze(session.id, .until(now.addingTimeInterval(minutes * 60)))
    } else {
        fail("snooze takes a duration such as 30m or 1h, or tomorrow, change, or off", code: 2)
    }
    do {
        try state.save()
    } catch {
        fail("could not save: \(error)")
    }
    switch state.snoozes[session.id] {
    case .until(let end): print("\(session.name): reminders paused until \(end.formatted(date: .abbreviated, time: .shortened))")
    case .untilChange: print("\(session.name): reminders paused until it asks something new")
    case nil: print("\(session.name): reminders on")
    }
}

/// Prints the settings as the app will use them, defaults filled in.
func settings() {
    struct Report: Encodable {
        let file: String
        let terminal: String?
        let claudePath: String?
        let preferAgentView: Bool
        let reminders: ReminderSettings
        let repos: RepoIndexSettings
        let naming: NamingSettings
        let hotkey: String?
    }
    let url = Settings.fileURL()
    let loaded = Settings.load(from: url)
    let report = Report(
        file: url.path, terminal: loaded.terminal, claudePath: loaded.claudePath,
        preferAgentView: loaded.preferAgentView ?? false, reminders: loaded.reminders ?? ReminderSettings(),
        repos: loaded.repos ?? RepoIndexSettings(), naming: loaded.naming ?? NamingSettings(),
        hotkey: loaded.hotkey?.display)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(report) else { fail("could not encode the settings") }
    print(String(decoding: data, as: UTF8.self))
}

func describe(_ problem: StoreProblem) -> String {
    switch problem {
    case .claudeNotFound(let candidates):
        "claude not found. Looked in:\n" + candidates.map { "  \($0)" }.joined(separator: "\n")
    case .cliFailed(let exitCode, let stderr): "claude agents failed (exit \(exitCode)): \(stderr)"
    case .invalidOutput: "claude agents printed something that is not a JSON list"
    case .timedOut: "claude agents did not answer in time"
    case .other(let text): "could not read sessions: \(text)"
    }
}

func doctor() async {
    let claude = locateClaude()
    print("claude: \(claude.path)")
    do {
        let result = try await CLIRunner().run(claude, ["--version"])
        if let version = CLIVersion(parsing: result.stdout) {
            print("version: \(version)")
        } else {
            print("version: could not parse \"\(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))\"")
        }
        let snapshot = try await AgentsCLISource(executable: claude).snapshot()
        print("sessions: \(snapshot.sessions.count) readable, \(snapshot.skipped) skipped")
        let enriched = JobStateSource().enrich(snapshot.sessions).filter { $0.job != nil }.count
        print("job details: available for \(enriched) of \(snapshot.sessions.count)")
    } catch {
        fail("claude is not usable: \(error)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "status":
    await status(arguments: Array(arguments.dropFirst()))
case "settings":
    switch arguments.dropFirst().first {
    case nil: settings()
    case "export": exportSettings(to: arguments.dropFirst(2).first)
    case "import": importSettings(from: arguments.dropFirst(2).first)
    case let other?: fail("unknown: porchlight settings \(other)\n\n\(usage)", code: 2)
    }
case "new":
    #if canImport(PorchlightMac)
    guard AppSignal.isAppRunning else { fail("Porchlight is not running. Start the app, or use: porchlight dispatch") }
    AppSignal.newSession.post()
    #else
    fail("new is only available on macOS")
    #endif
case "triage":
    await triage(arguments: Array(arguments.dropFirst()))
case "wrap-up":
    await wrapUp(arguments: Array(arguments.dropFirst()))
case "notes":
    notes(arguments: Array(arguments.dropFirst()))
case "pin", "unpin":
    await pin(arguments: arguments)
case "stop":
    await control(.stop, arguments: Array(arguments.dropFirst()))
case "rm":
    await control(.remove, arguments: Array(arguments.dropFirst()))
case "dispatch":
    await dispatch(arguments: Array(arguments.dropFirst()))
case "name":
    name(arguments: Array(arguments.dropFirst()))
case "repos":
    await repos(arguments: Array(arguments.dropFirst()))
case "snooze":
    await snooze(arguments: Array(arguments.dropFirst()))
case "tab":
    tab()
case "terminal":
    terminal(arguments: Array(arguments.dropFirst()))
case "open":
    await open(arguments: Array(arguments.dropFirst()))
case "watch":
    await watch(arguments: Array(arguments.dropFirst()))
case "companion":
    #if canImport(PorchlightMac)
    await companion()
    #else
    fail("companion is only available on macOS")
    #endif
case "doctor":
    await doctor()
case nil, "help", "--help", "-h":
    print(usage)
case let command?:
    fail("unknown command: \(command)\n\n\(usage)", code: 2)
}
