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
