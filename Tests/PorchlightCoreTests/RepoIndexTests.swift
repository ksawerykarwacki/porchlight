import Foundation
import Testing

@testable import PorchlightCore

/// A throwaway folder tree. Paths are given relative to its root; a trailing `/.git` makes a
/// clone, `/.git!` a linked worktree (where `.git` is a file).
struct Tree {
    let root: String

    init(_ entries: [String]) throws {
        // Resolved, so paths compare equal to what the scanner reports (/var is a link on macOS).
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("porchlight-tree-\(UUID().uuidString)")
        root = base.path
        for entry in entries {
            if entry.hasSuffix("/.git!") {
                let folder = base.appendingPathComponent(String(entry.dropLast(6)))
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Data("gitdir: /elsewhere\n".utf8).write(to: folder.appendingPathComponent(".git"))
            } else {
                try FileManager.default.createDirectory(at: base.appendingPathComponent(entry), withIntermediateDirectories: true)
            }
        }
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    func remove() { try? FileManager.default.removeItem(atPath: root) }

    /// What a scan of the whole tree finds, as paths relative to the root.
    func scan(maxDepth: Int = 3, excludes: [String] = RepoIndexSettings.defaultExcludes) -> [String] {
        RepoScanner.scan(roots: [root], maxDepth: maxDepth, excludes: excludes)
            .map { String($0.dropFirst(root.count + 1)) }
    }
}

@Suite struct RepoScanTests {
    @Test func findsClonesAndLinkedWorktreesButNotPlainFolders() throws {
        let tree = try Tree(["code/alpha/.git", "code/beta/.git!", "code/notes/drafts", "gamma/.git"])
        defer { tree.remove() }
        #expect(tree.scan() == ["code/alpha", "code/beta", "gamma"])
    }

    @Test func stopsAtTheDepthLimit() throws {
        let tree = try Tree(["one/.git", "a/two/.git", "a/b/three/.git", "a/b/c/four/.git"])
        defer { tree.remove() }
        #expect(tree.scan(maxDepth: 1) == ["one"])
        #expect(tree.scan(maxDepth: 2) == ["a/two", "one"])
        #expect(tree.scan(maxDepth: 3) == ["a/b/three", "a/two", "one"])
        #expect(tree.scan(maxDepth: 4) == ["a/b/c/four", "a/b/three", "a/two", "one"])
    }

    @Test func doesNotLookInsideARepository() throws {
        let tree = try Tree(["outer/.git", "outer/vendor/inner/.git", "outer/.claude/worktrees/fix/.git!"])
        defer { tree.remove() }
        #expect(tree.scan(maxDepth: 6) == ["outer"])
    }

    @Test func skipsExcludedNamesWildcardsAndPathEndings() throws {
        let tree = try Tree([
            "app/.git", "node_modules/dep/.git", "Library/thing/.git", "old.bundle/.git",
            "plain/.claude/worktrees/w1/.git!", "plain/sub/kept/.git",
        ])
        defer { tree.remove() }
        // The defaults leave out node_modules, Library and Claude's worktrees.
        #expect(tree.scan(maxDepth: 5) == ["app", "old.bundle", "plain/sub/kept"])
        // A wildcard matches a folder's name; a pattern with a slash matches the end of its path.
        #expect(tree.scan(maxDepth: 5, excludes: ["*.bundle", "plain/sub"]) == ["Library/thing", "app", "node_modules/dep"])
        // With nothing excluded, a hidden folder is still only entered if it is a repository.
        #expect(tree.scan(maxDepth: 5, excludes: []) == ["Library/thing", "app", "node_modules/dep", "old.bundle", "plain/sub/kept"])
    }

    @Test func aHiddenFolderCountsOnlyWhenItIsARepositoryItself() throws {
        let tree = try Tree([".dotfiles/.git", ".cache/tool/.git", "visible/.git"])
        defer { tree.remove() }
        #expect(tree.scan() == [".dotfiles", "visible"])
    }

    @Test func aRootThatIsARepositoryIsFoundAndLinksAreNotFollowed() throws {
        let tree = try Tree(["solo/.git", "real/inside/.git"])
        defer { tree.remove() }
        #expect(RepoScanner.scan(roots: [tree.path("solo")], maxDepth: 3, excludes: []) == [tree.path("solo")])
        // A link back to the top would loop, and a link to a repository would list it twice.
        try FileManager.default.createSymbolicLink(atPath: tree.path("real/loop"), withDestinationPath: tree.root)
        try FileManager.default.createSymbolicLink(atPath: tree.path("alias"), withDestinationPath: tree.path("real/inside"))
        #expect(tree.scan(maxDepth: 8) == ["real/inside", "solo"])
    }

    @Test func overlappingRootsListARepositoryOnceAndAMissingRootIsQuiet() throws {
        let tree = try Tree(["code/alpha/.git"])
        defer { tree.remove() }
        let found = RepoScanner.scan(roots: [tree.root, tree.path("code"), tree.path("gone")], maxDepth: 3, excludes: [])
        #expect(found == [tree.path("code/alpha")])
    }
}

@Suite struct RepoIndexTests {
    let home = "/Users/u"

    func index(scanned: [String], sessions: [String] = [], pinned: [String] = [], missing: Set<String> = []) -> RepoIndex {
        RepoIndex(
            scanned: scanned, sessionDirectories: sessions, settings: RepoIndexSettings(pinned: pinned), home: home,
            exists: { !missing.contains($0) })
    }

    @Test func sessionFoldersJoinAndAWorktreeCountsAsItsRepository() {
        let built = index(
            scanned: ["/Users/u/code/alpha"],
            sessions: ["/Users/u/code/alpha/.claude/worktrees/fix-login", "/Users/u/elsewhere/beta", "/Users/u/elsewhere/beta", ""])
        #expect(built.repos.map(\.path) == ["/Users/u/code/alpha", "/Users/u/elsewhere/beta"])
        let alpha = built.repos[0], beta = built.repos[1]
        #expect(alpha.isIndexed && alpha.hasSessions)
        // Known only from a session: outside every workspace root.
        #expect(!beta.isIndexed && beta.hasSessions)
        #expect(beta.name == "beta")
    }

    @Test func pinnedComeFirstAndStayWhenAScanNoLongerFindsThem() {
        let built = index(scanned: ["/Users/u/code/alpha", "/Users/u/code/zeta"], pinned: ["~/code/zeta", "~/old/kept"])
        #expect(built.repos.map(\.name) == ["kept", "zeta", "alpha"])
        #expect(built.repos.map(\.isPinned) == [true, true, false])
        // The pin was written with `~`; the index holds the real path.
        #expect(built.repos[0].path == "/Users/u/old/kept")
        #expect(!built.repos[0].isIndexed)
    }

    @Test func foldersThatAreGoneAreLeftOutEvenWhenPinned() {
        let built = index(
            scanned: ["/Users/u/code/alpha"], sessions: ["/Users/u/gone/session"], pinned: ["~/gone/pinned"],
            missing: ["/Users/u/gone/session", "/Users/u/gone/pinned"])
        #expect(built.repos.map(\.path) == ["/Users/u/code/alpha"])
    }

    @Test func theSamePathWrittenDifferentlyIsOneRepository() {
        let built = index(scanned: ["/Users/u/code/alpha/"], sessions: ["/Users/u/code/../code/alpha"], pinned: ["~/code/alpha"])
        #expect(built.repos.count == 1)
        #expect(built.repos[0] == Repo(path: "/Users/u/code/alpha", isPinned: true, isIndexed: true, hasSessions: true))
    }

    @Test func searchMatchesLettersInOrderAndPrefersTheNameAndWordStarts() {
        let built = index(scanned: [
            "/Users/u/code/porchlight", "/Users/u/code/payments-api", "/Users/u/code/api-gateway", "/Users/u/work/plain",
        ])
        #expect(built.matching("").count == 4)
        #expect(built.matching("por").map(\.name) == ["porchlight"])
        // "api" starts a name, and starts a word inside another.
        #expect(built.matching("api").map(\.name) == ["api-gateway", "payments-api"])
        // Letters in order, not together.
        #expect(built.matching("pcl").map(\.name) == ["porchlight"])
        // Several names can match; letters together at the start beat letters scattered inside.
        #expect(built.matching("pa").map(\.name) == ["payments-api", "plain", "api-gateway"])
        // Nothing in the name: the folder above still finds it, after name matches.
        #expect(built.matching("work").map(\.name) == ["plain"])
        // But only as typed: "uwk" is scattered through /Users/u/work and finds nothing.
        #expect(built.matching("uwk").isEmpty)
        #expect(built.matching("u/co").count == 3)
        #expect(built.matching("zzz").isEmpty)
        // Case and spaces do not matter.
        #expect(built.matching("PAY api").map(\.name) == ["payments-api"])
    }

    @Test func fuzzyScoresRankCloserMatchesHigher() throws {
        let whole = try #require(FuzzyMatch.score("api", in: "api"))
        let prefix = try #require(FuzzyMatch.score("api", in: "api-gateway"))
        let word = try #require(FuzzyMatch.score("api", in: "payments-api"))
        let scattered = try #require(FuzzyMatch.score("api", in: "a-pretty-index"))
        #expect(whole > prefix && prefix > word && word > scattered)
        #expect(FuzzyMatch.score("api", in: "ap") == nil)
        #expect(FuzzyMatch.score("ba", in: "ab") == nil)
        // The first letter of the text can only match once: no reaching before the start.
        #expect(FuzzyMatch.score("aa", in: "a") == nil)
        #expect(FuzzyMatch.score("aa", in: "aba") != nil)
    }

    @Test func rootsAndPinsAreAddedOnceAndWrittenWithATilde() {
        var settings = RepoIndexSettings()
        let added = settings.addRoot("/Users/u/code/", home: home)
        let addedAgain = settings.addRoot("~/code", home: home)
        #expect(added && !addedAgain)
        #expect(settings.roots == ["~/code"])
        settings.setPinned("/Users/u/code/alpha", true, home: home)
        settings.setPinned("~/code/alpha", true, home: home)
        #expect(settings.pinned == ["~/code/alpha"])
        #expect(settings.isPinned("/Users/u/code/alpha/", home: home))
        settings.setPinned("~/code/alpha", false, home: home)
        #expect(settings.pinned.isEmpty)
        let removed = settings.removeRoot("/Users/u/code", home: home)
        let removedAgain = settings.removeRoot("/Users/u/code", home: home)
        #expect(removed && !removedAgain)
        #expect(settings.roots.isEmpty)
    }

    @Test func settingsAreReadTolerantlyAndSurviveARoundTrip() throws {
        let odd = Data(#"{"repos": {"roots": ["~/code"], "maxDepth": 99, "excludes": "none", "pinned": ["~/code/a"]}, "terminal": "warp"}"#.utf8)
        let settings = try JSONDecoder().decode(Settings.self, from: odd)
        #expect(settings.terminal == "warp")
        let repos = try #require(settings.repos)
        #expect(repos.roots == ["~/code"])
        // A depth outside what makes sense, and excludes of the wrong type, fall back on their own.
        #expect(repos.maxDepth == RepoIndexSettings.defaultMaxDepth)
        #expect(repos.excludes == RepoIndexSettings.defaultExcludes)
        #expect(repos.pinned == ["~/code/a"])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-repos-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = Settings.fileURL(in: directory)
        var saved = Settings(terminal: "ghostty")
        saved.repos = RepoIndexSettings(roots: ["~/work"], maxDepth: 2, excludes: ["vendor"], pinned: ["~/work/x"])
        try saved.save(to: url)
        #expect(Settings.load(from: url) == saved)
        // No repos entry at all means none yet, not an error.
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).repos == nil)
    }
}
