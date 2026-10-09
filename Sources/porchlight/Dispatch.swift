import Foundation
import PorchlightCore

let dispatchUsage = """
    usage: porchlight dispatch [--dir DIR | --repo TEXT] [--name NAME | --no-name] [--model MODEL]
                               [--effort LEVEL] [--agent AGENT] [--permission-mode MODE]
                               [--worktree[=NAME]] [--open] [--json] PROMPT
    """

/// `porchlight dispatch`: start a background session in a folder, named from the template.
func dispatch(arguments: [String]) async {
    var request = DispatchRequest(directory: FileManager.default.currentDirectoryPath, prompt: "")
    var repoQuery: String?
    var explicitName = false
    var unnamed = false
    var openAfter = false
    var json = false
    var words: [String] = []

    var index = 0
    func value(for flag: String) -> String {
        index += 1
        guard index < arguments.count else { fail("\(flag) needs a value\n\(dispatchUsage)", code: 2) }
        return arguments[index]
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "--dir": request.directory = RepoPath.normalized(value(for: argument))
        case "--repo": repoQuery = value(for: argument)
        case "--name":
            request.name = value(for: argument)
            explicitName = true
        case "--no-name": unnamed = true
        case "--model": request.model = value(for: argument)
        case "--effort": request.effort = value(for: argument)
        case "--agent": request.agent = value(for: argument)
        case "--permission-mode": request.permissionMode = value(for: argument)
        case "--worktree": request.worktree = .unnamed
        case "--open": openAfter = true
        case "--json": json = true
        case "--":
            words += arguments[(index + 1)...]
            index = arguments.count
        default:
            if argument.hasPrefix("--worktree=") {
                request.worktree = .named(String(argument.dropFirst("--worktree=".count)))
            } else if argument.hasPrefix("--") {
                fail("unknown option \(argument)\n\(dispatchUsage)", code: 2)
            } else {
                words.append(argument)
            }
        }
        index += 1
    }
    request.prompt = words.joined(separator: " ")
    guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail(dispatchUsage, code: 2) }

    let settings = Settings.load()
    if let repoQuery {
        let repos = RepoIndex.build(settings: settings.repos ?? RepoIndexSettings(), sessionDirectories: await sessionDirectories())
        let ranked = RepoRanking(history: DispatchHistory.load()).ranked(repos, query: repoQuery)
        guard let best = ranked.first else { fail("no repository matches \"\(repoQuery)\"") }
        request.directory = best.path
    }
    if !explicitName, !unnamed {
        let template = NameTemplate(settings: settings.naming ?? NamingSettings())
        let name = template.name(prompt: request.prompt, directory: request.directory, branch: GitBranch.current(in: request.directory))
        request.name = name.isEmpty ? nil : name
    }

    let locator = ClaudeLocator(override: ProcessInfo.processInfo.environment["PORCHLIGHT_CLAUDE"] ?? settings.claudePath)
    guard let claude = locator.locate() else { fail(describe(.claudeNotFound(candidates: locator.candidates()))) }

    let started: Dispatched
    do {
        started = try await Dispatcher(claude: claude).dispatch(request)
    } catch let error as DispatchError {
        var message = error.message
        if let command = error.command { message += "\n\nThe command was:\n  \(command)" }
        fail(message)
    } catch {
        fail("could not start the session: \(error)")
    }

    var history = DispatchHistory.load()
    history.record(.init(directory: started.directory, name: started.name, model: request.model, date: Date()))
    try? history.save()

    if json {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(started) else { fail("could not encode the result") }
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("Started \(started.name ?? "a session") (\(started.id)) in \(RepoPath.abbreviated(started.directory))")
    }
    if openAfter {
        await open(arguments: [started.id])
    }
}

/// `porchlight stop <id>` and `porchlight rm <id>`. Typing the command is the confirmation; no
/// flag is passed on, so nothing Claude Code refuses can be forced from here.
func control(_ action: SessionAction, arguments: [String]) async {
    let name = action == .stop ? "stop" : "rm"
    guard arguments.count == 1, let id = arguments.first, !id.hasPrefix("-") else {
        fail("usage: porchlight \(name) <id>", code: 2)
    }
    let settings = Settings.load()
    let locator = ClaudeLocator(override: ProcessInfo.processInfo.environment["PORCHLIGHT_CLAUDE"] ?? settings.claudePath)
    guard let claude = locator.locate() else { fail(describe(.claudeNotFound(candidates: locator.candidates()))) }
    switch await SessionControl(claude: claude).run(action, id: id) {
    case .done(let text): print(text.isEmpty ? action.done(name: id) : text)
    case .refused(let text): fail(text)
    case .couldNotRun(let text): fail(text)
    }
}

/// `porchlight pin <id> [--quiet]` and `porchlight unpin <id>`. The id must be a session that
/// exists, so a typo does not leave a pin on nothing.
func pin(arguments: [String]) async {
    let pinning = arguments.first == "pin"
    var rest = Array(arguments.dropFirst())
    let quiet = rest.contains("--quiet")
    rest.removeAll { $0 == "--quiet" }
    guard rest.count == 1, let id = rest.first, !id.hasPrefix("-"), pinning || !quiet else {
        fail("usage: porchlight pin <id> [--quiet]\n       porchlight unpin <id>", code: 2)
    }
    let store = liveStore()
    await store.refresh()
    let snapshot = await store.snapshot
    if let problem = snapshot.problem { fail(describe(problem)) }
    guard let session = snapshot.sessions.first(where: { $0.id == id }) else { fail("no session has the id \(id)") }
    var pins = Pins.load()
    if pinning {
        pins.pin(id, quiet: quiet)
    } else {
        pins.unpin(id)
    }
    do {
        try pins.save()
    } catch {
        fail("could not save the pins: \(error.localizedDescription)")
    }
    print(pinning ? "Pinned \(session.name)" + (quiet ? "; its reminders are off" : "") : "Unpinned \(session.name)")
}

/// `porchlight triage [--json]`: what could be cleared away, and what would be lost.
func triage(arguments: [String]) async {
    let store = liveStore()
    await store.refresh()
    let snapshot = await store.snapshot
    if let problem = snapshot.problem { fail(describe(problem)) }
    let settings = Settings.load().triage ?? TriageSettings()
    let items = await TriageGatherer().items(sessions: snapshot.sessions, pins: Pins.load(), settings: settings)

    if arguments.contains("--json") {
        struct Row: Encodable {
            let id: String
            let name: String
            let repo: String
            let state: String
            let verdict: String
            let reason: String
            let pullRequest: String
            let branch: String?
            let worktree: String?
            let uncommitted: Int?
            let unpushed: Int?
        }
        let rows = items.map { item in
            Row(
                id: item.id, name: item.session.name, repo: item.session.location.repoName, state: item.session.summary.state.rawValue,
                verdict: item.verdict.rawValue, reason: item.reason, pullRequest: item.facts.pullRequest.summary, branch: item.facts.branch,
                worktree: item.facts.worktree?.path, uncommitted: item.facts.worktree?.uncommitted, unpushed: item.facts.worktree?.unpushed)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(["sessions": rows]) else { fail("could not encode the triage") }
        print(String(decoding: data, as: UTF8.self))
        return
    }

    if items.isEmpty {
        print("Nothing to triage: no session is finished, stopped or waiting for long.")
        return
    }
    for verdict in TriageVerdict.allCases {
        let group = items.filter { $0.verdict == verdict }
        guard !group.isEmpty else { continue }
        print("\n\(verdict.title) (\(group.count)): \(verdict.explanation)")
        for item in group {
            print("  \(item.id)  \(item.session.name)  [\(item.session.location.repoName)]  \(item.reason)")
        }
    }
}
