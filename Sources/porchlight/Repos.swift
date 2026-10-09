import Foundation
import PorchlightCore

/// The folders of the sessions that exist, or none when claude cannot be asked: the list of
/// repositories is still useful without them.
func sessionDirectories() async -> [String] {
    let store = SessionStore.live(locator: ClaudeLocator(override: ProcessInfo.processInfo.environment["PORCHLIGHT_CLAUDE"]))
    await store.refresh()
    return await store.snapshot.sessions.map(\.summary.cwd)
}

func saveSettings(_ change: (inout Settings) -> Void) {
    let url = Settings.fileURL()
    var settings = Settings.load(from: url)
    change(&settings)
    do {
        try settings.save(to: url)
    } catch {
        fail("could not save \(url.path): \(error.localizedDescription)")
    }
}

/// `porchlight repos`: list, search, and manage where repositories are looked for.
func repos(arguments: [String]) async {
    var arguments = arguments
    let json = arguments.contains("--json")
    arguments.removeAll { $0 == "--json" }

    switch arguments.first {
    case "root":
        guard arguments.count == 3, ["add", "remove"].contains(arguments[1]) else {
            fail("usage: porchlight repos root add|remove <folder>", code: 2)
        }
        let path = RepoPath.normalized(arguments[2])
        if arguments[1] == "add" {
            guard RepoIndex.directoryExists(path) else { fail("\(path) is not a folder") }
            saveSettings { settings in
                var repos = settings.repos ?? RepoIndexSettings()
                repos.addRoot(path)
                settings.repos = repos
            }
            print("Looking for repositories in \(RepoPath.abbreviated(path))")
        } else {
            var removed = false
            saveSettings { settings in
                var repos = settings.repos ?? RepoIndexSettings()
                removed = repos.removeRoot(path)
                settings.repos = repos
            }
            print(removed ? "No longer looking in \(RepoPath.abbreviated(path))" : "\(RepoPath.abbreviated(path)) was not a workspace root")
        }
        return
    case "pin", "unpin":
        guard arguments.count == 2 else { fail("usage: porchlight repos pin|unpin <folder>", code: 2) }
        let path = RepoPath.normalized(arguments[1])
        let pin = arguments[0] == "pin"
        if pin, !RepoIndex.directoryExists(path) { fail("\(path) is not a folder") }
        saveSettings { settings in
            var repos = settings.repos ?? RepoIndexSettings()
            repos.setPinned(path, pin)
            settings.repos = repos
        }
        print(pin ? "Pinned \(RepoPath.abbreviated(path))" : "Unpinned \(RepoPath.abbreviated(path))")
        return
    default:
        break
    }

    let settings = Settings.load().repos ?? RepoIndexSettings()
    let index = RepoIndex.build(settings: settings, sessionDirectories: await sessionDirectories())
    let query = arguments.joined(separator: " ")
    let found = index.matching(query)

    if json {
        struct Report: Encodable {
            let roots: [String]
            let maxDepth: Int
            let excludes: [String]
            let repos: [Repo]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let report = Report(roots: settings.roots, maxDepth: settings.maxDepth, excludes: settings.excludes, repos: found)
        guard let data = try? encoder.encode(report) else { fail("could not encode the repositories") }
        print(String(decoding: data, as: UTF8.self))
        return
    }

    if settings.roots.isEmpty {
        print("No workspace roots yet. Add one with: porchlight repos root add <folder>")
    }
    if found.isEmpty {
        print(query.isEmpty ? "No repositories found." : "No repository matches \"\(query)\".")
        return
    }
    let width = found.map(\.name.count).max() ?? 0
    for repo in found {
        let marks = [repo.isPinned ? "pinned" : nil, repo.hasSessions ? "has sessions" : nil].compactMap { $0 }
        let note = marks.isEmpty ? "" : "  (\(marks.joined(separator: ", ")))"
        print("\(repo.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(repo.displayPath())\(note)")
    }
}

/// `porchlight name`: the name the template gives a prompt, for a folder (default: this one).
func name(arguments: [String]) {
    var arguments = arguments
    var directory = FileManager.default.currentDirectoryPath
    if let flag = arguments.firstIndex(of: "--dir") {
        guard flag + 1 < arguments.count else { fail("usage: porchlight name [--dir DIR] PROMPT", code: 2) }
        directory = RepoPath.normalized(arguments[flag + 1])
        arguments.removeSubrange(flag...(flag + 1))
    }
    guard !arguments.isEmpty else { fail("usage: porchlight name [--dir DIR] PROMPT", code: 2) }
    let template = NameTemplate(settings: Settings.load().naming ?? NamingSettings())
    print(template.name(prompt: arguments.joined(separator: " "), directory: directory, branch: GitBranch.current(in: directory)))
}
