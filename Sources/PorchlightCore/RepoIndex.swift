import Foundation

/// Where to look for repositories. Unknown keys are ignored and each value is read on its own.
public struct RepoIndexSettings: Codable, Sendable, Equatable {
    public static let defaultMaxDepth = 3
    public static let defaultExcludes = ["node_modules", ".git", ".claude/worktrees", "Library"]

    /// Folders to search. `~` stands for the home folder. Empty until the user adds one.
    public var roots: [String]
    /// How many folders below a root to look. A root's own children are depth 1.
    public var maxDepth: Int
    /// Folders to skip: a name (`node_modules`), a wildcard name (`*.bundle`), or the end of a
    /// path (`.claude/worktrees`).
    public var excludes: [String]
    /// Repositories kept at the top of the list, and kept in it even when a search no longer
    /// finds them.
    public var pinned: [String]

    public init(
        roots: [String] = [], maxDepth: Int = RepoIndexSettings.defaultMaxDepth,
        excludes: [String] = RepoIndexSettings.defaultExcludes, pinned: [String] = []
    ) {
        self.roots = roots
        self.maxDepth = maxDepth
        self.excludes = excludes
        self.pinned = pinned
    }

    private enum CodingKeys: String, CodingKey {
        case roots, maxDepth, excludes, pinned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roots = (try? c.decodeIfPresent([String].self, forKey: .roots)) ?? []
        let depth = (try? c.decodeIfPresent(Int.self, forKey: .maxDepth)) ?? Self.defaultMaxDepth
        // A depth nobody means: zero would find nothing, and a huge one would walk the disk.
        maxDepth = (1...8).contains(depth) ? depth : Self.defaultMaxDepth
        excludes = (try? c.decodeIfPresent([String].self, forKey: .excludes)) ?? Self.defaultExcludes
        pinned = (try? c.decodeIfPresent([String].self, forKey: .pinned)) ?? []
    }

    /// Adds a root, or does nothing if it is already there. Returns whether it was added.
    @discardableResult
    public mutating func addRoot(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let wanted = RepoPath.normalized(path, home: home)
        guard !roots.contains(where: { RepoPath.normalized($0, home: home) == wanted }) else { return false }
        roots.append(RepoPath.abbreviated(wanted, home: home))
        return true
    }

    @discardableResult
    public mutating func removeRoot(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let wanted = RepoPath.normalized(path, home: home)
        let before = roots.count
        roots.removeAll { RepoPath.normalized($0, home: home) == wanted }
        return roots.count != before
    }

    public func isPinned(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let wanted = RepoPath.normalized(path, home: home)
        return pinned.contains { RepoPath.normalized($0, home: home) == wanted }
    }

    public mutating func setPinned(_ path: String, _ pin: Bool, home: String = NSHomeDirectory()) {
        let wanted = RepoPath.normalized(path, home: home)
        pinned.removeAll { RepoPath.normalized($0, home: home) == wanted }
        if pin { pinned.append(RepoPath.abbreviated(wanted, home: home)) }
    }
}

/// Paths as people write them and as the file system wants them.
public enum RepoPath {
    /// An absolute path without `~`, `.`/`..` parts or a trailing slash.
    public static func normalized(_ path: String, home: String = NSHomeDirectory()) -> String {
        var path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + String(path.dropFirst(1))
        }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// The path with the home folder written as `~`, for display and for the settings file.
    public static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }
}

/// A folder a session can be started in.
public struct Repo: Sendable, Equatable, Identifiable, Codable {
    /// Absolute path.
    public let path: String
    public let name: String
    public var isPinned: Bool
    /// True when a search of the workspace roots found it; false when it is only known from a
    /// session or a pin.
    public var isIndexed: Bool
    /// True when a session lives there now, or did.
    public var hasSessions: Bool

    public var id: String { path }

    public init(path: String, isPinned: Bool = false, isIndexed: Bool = true, hasSessions: Bool = false) {
        self.path = path
        self.name = path.split(separator: "/").last.map(String.init) ?? path
        self.isPinned = isPinned
        self.isIndexed = isIndexed
        self.hasSessions = hasSessions
    }

    /// The path with the home folder written as `~`.
    public func displayPath(home: String = NSHomeDirectory()) -> String {
        RepoPath.abbreviated(path, home: home)
    }
}

/// Finds repositories on disk.
public enum RepoScanner {
    /// Every folder under `roots` that holds `.git`, whether a folder (a clone) or a file (a
    /// linked worktree or a submodule). A repository is not searched for more repositories.
    /// Symbolic links are not followed, so a link back up the tree cannot loop.
    public static func scan(roots: [String], maxDepth: Int, excludes: [String], fileManager: FileManager = .default) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        for root in roots {
            visit(root, depth: 0, maxDepth: maxDepth, excludes: excludes, fileManager: fileManager, found: &found, seen: &seen)
        }
        return found
    }

    public static func isRepository(_ path: String, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: path + "/.git")
    }

    /// Whether a folder is left out. `relative` is its path below the root being searched.
    public static func isExcluded(name: String, path: String, excludes: [String]) -> Bool {
        excludes.contains { pattern in
            let pattern = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !pattern.isEmpty else { return false }
            if pattern.contains("/") {
                return path == "/" + pattern || path.hasSuffix("/" + pattern)
            }
            return fnmatch(pattern, name, 0) == 0
        }
    }

    private static func visit(
        _ path: String, depth: Int, maxDepth: Int, excludes: [String], fileManager: FileManager,
        found: inout [String], seen: inout Set<String>
    ) {
        if isRepository(path, fileManager: fileManager) {
            if seen.insert(path).inserted { found.append(path) }
            return
        }
        guard depth < maxDepth else { return }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else { return }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isDirectory == true, values.isSymbolicLink != true else {
                continue
            }
            let name = child.lastPathComponent
            let childPath = path == "/" ? "/" + name : path + "/" + name
            if isExcluded(name: name, path: childPath, excludes: excludes) { continue }
            // Hidden folders hold caches and tool state; one is only of interest if it is a
            // repository itself (dotfiles, for example).
            if name.hasPrefix("."), !isRepository(childPath, fileManager: fileManager) { continue }
            visit(childPath, depth: depth + 1, maxDepth: maxDepth, excludes: excludes, fileManager: fileManager, found: &found, seen: &seen)
        }
    }
}

/// The folders offered when starting a session: what a search of the workspace roots found, the
/// folders of sessions that exist, and whatever the user pinned.
public struct RepoIndex: Sendable, Equatable {
    /// Pinned first, then by name. Ranking by use is applied when searching.
    public let repos: [Repo]

    public init(repos: [Repo]) {
        self.repos = repos.sorted(by: RepoIndex.listOrder)
    }

    /// - Parameters:
    ///   - scanned: absolute paths from `RepoScanner.scan`.
    ///   - sessionDirectories: the `cwd` of every session; a Claude worktree counts as its repository.
    ///   - exists: whether a folder is still there. Folders that are gone are left out, pinned or not.
    public init(
        scanned: [String], sessionDirectories: [String] = [], settings: RepoIndexSettings = RepoIndexSettings(),
        home: String = NSHomeDirectory(), exists: (String) -> Bool = RepoIndex.directoryExists
    ) {
        var byPath: [String: Repo] = [:]
        var order: [String] = []
        func add(_ raw: String, indexed: Bool = false, sessions: Bool = false, pinned: Bool = false) {
            let path = RepoPath.normalized(raw, home: home)
            guard path != "/", !path.isEmpty else { return }
            if byPath[path] == nil {
                guard exists(path) else { return }
                byPath[path] = Repo(path: path, isPinned: false, isIndexed: false, hasSessions: false)
                order.append(path)
            }
            if indexed { byPath[path]?.isIndexed = true }
            if sessions { byPath[path]?.hasSessions = true }
            if pinned { byPath[path]?.isPinned = true }
        }
        for path in scanned { add(path, indexed: true) }
        for cwd in sessionDirectories where !cwd.isEmpty { add(RepoLocation(cwd: cwd).repoRoot, sessions: true) }
        for path in settings.pinned { add(path, pinned: true) }
        self.init(repos: order.compactMap { byPath[$0] })
    }

    /// Searches the roots in `settings` and builds the index. Reads the disk: call off the main thread.
    public static func build(
        settings: RepoIndexSettings, sessionDirectories: [String] = [], home: String = NSHomeDirectory(), fileManager: FileManager = .default
    ) -> RepoIndex {
        let roots = settings.roots.map { RepoPath.normalized($0, home: home) }
        let scanned = RepoScanner.scan(roots: roots, maxDepth: settings.maxDepth, excludes: settings.excludes, fileManager: fileManager)
        return RepoIndex(scanned: scanned, sessionDirectories: sessionDirectories, settings: settings, home: home)
    }

    public static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    static func listOrder(_ a: Repo, _ b: Repo) -> Bool {
        if a.isPinned != b.isPinned { return a.isPinned }
        let byName = a.name.localizedCaseInsensitiveCompare(b.name)
        return byName == .orderedSame ? a.path < b.path : byName == .orderedAscending
    }

    /// The repositories matching what was typed, best match first. Empty text returns them all.
    public func matching(_ query: String, home: String = NSHomeDirectory()) -> [Repo] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return repos }
        let scored: [(repo: Repo, score: Int)] = repos.compactMap { repo in
            FuzzyMatch.score(query, name: repo.name, path: repo.displayPath(home: home)).map { (repo, $0) }
        }
        return scored
            .sorted { a, b in a.score != b.score ? a.score > b.score : RepoIndex.listOrder(a.repo, b.repo) }
            .map(\.repo)
    }
}

/// Matching what was typed against a name: the letters must appear in order, and the closer
/// together and the nearer the start of a word they are, the better.
public enum FuzzyMatch {
    /// Nil when `query` does not match `candidate` at all.
    public static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        let hay = Array(candidate.lowercased())
        guard !needle.isEmpty else { return 0 }
        guard needle.count <= hay.count else { return nil }

        // Best score for matching the first `i` letters with the last one at position `j`.
        let none = Int.min / 2
        var previous = [Int](repeating: none, count: hay.count)
        var total = none
        for (i, letter) in needle.enumerated() {
            var current = [Int](repeating: none, count: hay.count)
            var bestBefore = none
            for j in hay.indices {
                // `bestBefore` is the best way to have matched the earlier letters before `j`.
                if j > 0, i > 0 { bestBefore = max(bestBefore, previous[j - 1]) }
                guard hay[j] == letter else { continue }
                var bonus = 1
                if j == 0 {
                    bonus += 6
                } else if !hay[j - 1].isLetter && !hay[j - 1].isNumber {
                    bonus += 4
                }
                if i == 0 {
                    current[j] = bonus
                } else if j > 0 {
                    let afterGap = bestBefore == none ? none : bestBefore + bonus
                    let adjacent = previous[j - 1] == none ? none : previous[j - 1] + bonus + 8
                    current[j] = max(afterGap, adjacent)
                }
            }
            previous = current
            if i == needle.count - 1 { total = current.max() ?? none }
        }
        guard total > none / 2 else { return nil }
        // A whole-name match beats the same letters inside a longer name.
        return total * 4 - min(hay.count - needle.count, 40)
    }

    /// The name is matched loosely, letters in order. The rest of the path only counts when it
    /// contains the text as typed: scattered letters are found in almost any long path.
    public static func score(_ query: String, name: String, path: String) -> Int? {
        if let score = score(query, in: name) { return score + 1000 }
        let needle = query.lowercased().filter { !$0.isWhitespace }
        let lowered = path.lowercased()
        guard !needle.isEmpty, let range = lowered.range(of: needle) else { return nil }
        // Nearer the end of the path is nearer the repository itself.
        return -lowered.distance(from: range.upperBound, to: lowered.endIndex)
    }
}
