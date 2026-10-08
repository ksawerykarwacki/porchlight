import Foundation
import PorchlightCore

let usage = """
    porchlight — see which Claude Code background sessions are waiting on you

    Usage:
      porchlight status [--json] [--active]   List sessions (--active leaves out finished ones)
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

func age(since date: Date?) -> String {
    guard let date else { return "" }
    let seconds = Int(Date().timeIntervalSince(date))
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(seconds / 60)m"
    case ..<86400: return "\(seconds / 3600)h"
    default: return "\(seconds / 86400)d"
    }
}

func status(arguments: [String]) async {
    let claude = locateClaude()
    let snapshot: AgentsSnapshot
    do {
        snapshot = try await AgentsCLISource(executable: claude).snapshot(includeCompleted: !arguments.contains("--active"))
    } catch AgentsCLIError.failed(let code, let stderr) {
        fail("claude agents failed (exit \(code)): \(stderr)")
    } catch {
        fail("could not read sessions: \(error)")
    }
    let sessions = JobStateSource().enrich(snapshot.sessions)

    if arguments.contains("--json") {
        do {
            print(try StatusReport(sessions: sessions, skippedRows: snapshot.skipped).json())
        } catch {
            fail("could not encode status: \(error)")
        }
        return
    }

    let waiting = sessions.filter(\.needsHuman)
    print("\(waiting.count) waiting on you, \(sessions.count) sessions in total")
    for session in sessions.sorted(by: { ($0.needsHuman ? 0 : 1, $0.name) < ($1.needsHuman ? 0 : 1, $1.name) }) {
        let location = session.location
        let place = location.worktreeName.map { "\(location.repoName) (\($0))" } ?? location.repoName
        let waited = age(since: session.waitingSince)
        print("  \(session.id)  \(session.summary.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0))"
            + "  \(session.name)  [\(place)]" + (waited.isEmpty ? "" : "  waiting \(waited)"))
        switch session.needs {
        case .question(let text): print("      asks: \(text)")
        case .approval(let tool, let detail): print("      wants approval for \(tool): \(detail)")
        case .other(let text): print("      needs: \(text)")
        case nil: break
        }
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
case "doctor":
    await doctor()
case nil, "help", "--help", "-h":
    print(usage)
case let command?:
    fail("unknown command: \(command)\n\n\(usage)", code: 2)
}
