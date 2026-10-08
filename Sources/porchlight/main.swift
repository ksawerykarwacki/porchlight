import Foundation
import PorchlightCore

let usage = """
    porchlight — see which Claude Code background sessions are waiting on you

    Usage:
      porchlight status [--json] [--active]   List sessions (--active leaves out finished ones)
      porchlight watch [--once]               Print one JSON line now and one after every change
      porchlight doctor                       Check that the claude CLI can be found and used
      porchlight help

    Environment:
      PORCHLIGHT_CLAUDE   Path to the claude executable, overriding the search
    """

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func locateClaude() -> URL {
    let locator = ClaudeLocator(override: ProcessInfo.processInfo.environment["PORCHLIGHT_CLAUDE"])
    guard let url = locator.locate() else {
        fail("claude not found. Looked in:\n" + locator.candidates().map { "  \($0)" }.joined(separator: "\n"))
    }
    return url
}

func status(arguments: [String]) async {
    let store = SessionStore.live()
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
            print(try StatusReport(sessions: sessions, skippedRows: snapshot.skippedRows).json())
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
    let store = SessionStore.live()
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
case "watch":
    await watch(arguments: Array(arguments.dropFirst()))
case "doctor":
    await doctor()
case nil, "help", "--help", "-h":
    print(usage)
case let command?:
    fail("unknown command: \(command)\n\n\(usage)", code: 2)
}
