import Foundation
import Testing

@testable import PorchlightCore

@Suite struct DispatcherTests {
    func capabilities() throws -> DispatchCapabilities {
        DispatchCapabilities(help: try Fixtures.text("claude-help.txt"))
    }

    func dispatcher(_ fake: FakeClaude, mode: String = "normal") -> Dispatcher {
        Dispatcher(claude: Fixtures.fakeClaude, environment: fake.environment(mode: mode))
    }

    /// What the stand-in was started with for `--bg`: its folder, then its arguments.
    func backgroundCall(_ fake: FakeClaude) throws -> (directory: String, arguments: [String]) {
        let recorded = try fake.recorded()
        let start = try #require(recorded.lastIndex(of: "--bg"))
        return (recorded[start - 1], Array(recorded[start...]))
    }

    @Test func readsWhatTheInstalledCLISupportsFromItsHelp() throws {
        let known = try capabilities()
        #expect(known.background && known.name && known.model && known.agent && known.worktree)
        #expect(known.effortLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(known.permissionModes == ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"])
        // Skipping every check is not something Porchlight offers.
        #expect(known.offeredPermissionModes == ["acceptEdits", "auto", "manual", "dontAsk", "plan"])
    }

    @Test func anOlderCLIOffersOnlyWhatItLists() throws {
        let old = DispatchCapabilities(help: try Fixtures.text("claude-help-old.txt"))
        #expect(old.background)
        // --agents, --fallback-model and --remote-control-session-name-prefix are other options.
        #expect(!old.agent && !old.model && !old.name && !old.worktree)
        // --effort is there but lists no levels, and the next option's choices are not its own.
        #expect(old.effortLevels.isEmpty)
        #expect(old.permissionModes.isEmpty)
        #expect(DispatchCapabilities(help: "") == DispatchCapabilities())
    }

    @Test func buildsOneArgumentPerValueWithThePromptAfterADoubleDash() throws {
        let request = DispatchRequest(
            directory: "/tmp", prompt: "  --dangerously-skip-permissions; rm -rf \"$HOME\"\nsecond `line`  ", name: "my name",
            model: "opus", effort: "high", agent: "reviewer", permissionMode: "acceptEdits", worktree: .named("-odd name"))
        let arguments = try Dispatcher.arguments(for: request, capabilities: try capabilities())
        #expect(arguments == [
            "--bg", "--name", "my name", "--model", "opus", "--effort", "high", "--agent", "reviewer",
            "--permission-mode", "acceptEdits", "--worktree=-odd name",
            "--", "--dangerously-skip-permissions; rm -rf \"$HOME\"\nsecond `line`",
        ])
        // Nothing optional: just the prompt.
        #expect(try Dispatcher.arguments(for: DispatchRequest(directory: "/tmp", prompt: "hello"), capabilities: try capabilities()) == ["--bg", "--", "hello"])
        // Blank values are the same as none.
        let blank = DispatchRequest(directory: "/tmp", prompt: "hello", name: " ", model: "", effort: "  ", worktree: .named(" "))
        #expect(try Dispatcher.arguments(for: blank, capabilities: try capabilities()) == ["--bg", "--worktree", "--", "hello"])
        #expect(try Dispatcher.arguments(for: DispatchRequest(directory: "/tmp", prompt: "x", worktree: .unnamed), capabilities: try capabilities()) == ["--bg", "--worktree", "--", "x"])
    }

    @Test func refusesWhatTheCLIDoesNotList() throws {
        let known = try capabilities()
        let old = DispatchCapabilities(help: try Fixtures.text("claude-help-old.txt"))
        func error(_ request: DispatchRequest, _ capabilities: DispatchCapabilities) -> DispatchError? {
            do {
                _ = try Dispatcher.arguments(for: request, capabilities: capabilities)
                return nil
            } catch {
                return error as? DispatchError
            }
        }
        #expect(error(DispatchRequest(directory: "/tmp", prompt: " \n "), known) == .emptyPrompt)
        #expect(error(DispatchRequest(directory: "/tmp", prompt: "x"), DispatchCapabilities()) == .backgroundNotSupported)
        #expect(error(DispatchRequest(directory: "/tmp", prompt: "x", effort: "extreme"), known) == .notSupported("the effort level \"extreme\""))
        #expect(error(DispatchRequest(directory: "/tmp", prompt: "x", permissionMode: "bypassPermissions"), known) == .notSupported("the permission mode \"bypassPermissions\""))
        #expect(error(DispatchRequest(directory: "/tmp", prompt: "x", model: "opus"), old) == .notSupported("choosing a model (--model)"))
        #expect(error(DispatchRequest(directory: "/tmp", prompt: "x", agent: "a"), old) == .notSupported("choosing an agent (--agent)"))
        #expect(error(DispatchRequest(directory: "/tmp", prompt: "x", worktree: .unnamed), old) == .notSupported("worktrees (--worktree)"))
        // A name is a nicety: without --name the session starts unnamed rather than not at all.
        #expect(try Dispatcher.arguments(for: DispatchRequest(directory: "/tmp", prompt: "x", name: "n"), capabilities: old) == ["--bg", "--", "x"])
    }

    @Test func startsASessionInTheChosenFolderAndReturnsItsId() async throws {
        let fake = try FakeClaude()
        let request = DispatchRequest(directory: fake.scratch.path, prompt: "fix the login form", name: "fix-login-form", effort: "low")
        let started = try await dispatcher(fake).dispatch(request)
        #expect(started.id == "4cb41c2a")
        #expect(started.name == "fix-login-form")
        #expect(URL(fileURLWithPath: started.directory).resolvingSymlinksInPath() == fake.scratch.resolvingSymlinksInPath())

        let call = try backgroundCall(fake)
        #expect(URL(fileURLWithPath: call.directory).resolvingSymlinksInPath() == fake.scratch.resolvingSymlinksInPath())
        #expect(call.arguments == ["--bg", "--name", "fix-login-form", "--effort", "low", "--", "fix the login form"])
        // The help was asked for first, in no particular folder.
        #expect(try fake.recorded().contains("--help"))
    }

    @Test func anUnnamedSessionTakesTheNameClaudeGaveIt() async throws {
        let fake = try FakeClaude()
        let started = try await dispatcher(fake).dispatch(DispatchRequest(directory: fake.scratch.path, prompt: "hello"), capabilities: try capabilities())
        #expect(started.name == "probe")
        // Capabilities were passed in, so the help was not read again.
        #expect(try !fake.recorded().contains("--help"))
    }

    @Test func reportsAnUntrustedFolderWithTheFolderAndTheCommand() async throws {
        let fake = try FakeClaude()
        let request = DispatchRequest(directory: fake.scratch.path, prompt: "it's here", name: "n")
        do {
            _ = try await dispatcher(fake, mode: "untrusted").dispatch(request)
            Issue.record("expected the trust refusal")
        } catch let error as DispatchError {
            #expect(error.isUntrustedFolder)
            #expect(error.untrustedFolder?.hasSuffix(fake.scratch.lastPathComponent) == true)
            #expect(error.message.contains("accept the trust prompt"))
            // The command is one a person can paste: folder first, every argument quoted.
            let command = try #require(error.command)
            #expect(command.hasPrefix("cd "))
            #expect(command.hasSuffix("--bg --name n -- 'it'\\''s here'"))
        }
    }

    @Test func passesOnTheCLIsOwnWordsWhenItFails() async throws {
        let fake = try FakeClaude()
        let request = DispatchRequest(directory: fake.scratch.path, prompt: "x")
        do {
            _ = try await dispatcher(fake, mode: "refuse").dispatch(request)
            Issue.record("expected a failure")
        } catch let error as DispatchError {
            #expect(error.message == "error: unknown option '--model'")
            #expect(!error.isUntrustedFolder)
            #expect(error.command != nil)
        }
        do {
            _ = try await dispatcher(fake, mode: "no-id").dispatch(request)
            Issue.record("expected a failure")
        } catch let error as DispatchError {
            #expect(error == .noSessionID(output: "started something", command: try #require(error.command)))
            #expect(error.message.contains("started something"))
        }
    }

    @Test func neverStartsAnythingForAMissingFolderOrAnEmptyPrompt() async throws {
        let fake = try FakeClaude()
        let missing = fake.scratch.appendingPathComponent("gone").path
        await #expect(throws: DispatchError.notAFolder(missing)) {
            _ = try await dispatcher(fake).dispatch(DispatchRequest(directory: missing, prompt: "x"))
        }
        await #expect(throws: DispatchError.emptyPrompt) {
            _ = try await dispatcher(fake).dispatch(DispatchRequest(directory: fake.scratch.path, prompt: "  "))
        }
        #expect(try !fake.recorded().contains("--bg"))
        await #expect(throws: DispatchError.self) {
            _ = try await Dispatcher(claude: URL(fileURLWithPath: "/nonexistent/claude")).dispatch(
                DispatchRequest(directory: fake.scratch.path, prompt: "x"), capabilities: try capabilities())
        }
    }

    @Test func readsTheNameFromTheStartedLine() {
        #expect(DispatchOutput.sessionName(from: "backgrounded · \u{1B}[36m4cb41c2a\u{1B}[39m · fix login form\n  claude agents   list") == "fix login form")
        #expect(DispatchOutput.sessionName(from: "backgrounded · 4cb41c2a\n  hint") == nil)
        #expect(DispatchOutput.sessionName(from: "nothing") == nil)
    }
}

@Suite struct RepoRankingTests {
    let now = Date(timeIntervalSince1970: 1_791_540_000)
    let home = "/Users/u"

    func index(_ names: [String], pinned: [String] = [], sessions: [String] = []) -> RepoIndex {
        RepoIndex(
            scanned: names.map { "/Users/u/code/\($0)" }, sessionDirectories: sessions.map { "/Users/u/code/\($0)" },
            settings: RepoIndexSettings(pinned: pinned.map { "~/code/\($0)" }), home: home, exists: { _ in true })
    }

    func history(_ uses: [(String, daysAgo: Double)]) -> DispatchHistory {
        DispatchHistory(entries: uses.map { .init(directory: "/Users/u/code/\($0.0)", date: now.addingTimeInterval(-$0.daysAgo * 86400)) })
    }

    @Test func keepsOnlyTheLastTwentyNewestFirst() {
        var history = DispatchHistory()
        for number in 1...25 {
            history.record(.init(directory: "/r/\(number)", name: "n\(number)", model: "opus", date: now.addingTimeInterval(Double(number))))
        }
        #expect(history.entries.count == 20)
        #expect(history.last?.directory == "/r/25")
        #expect(history.entries.last?.directory == "/r/6")
        // Recorded out of order, it is still newest first.
        history.record(.init(directory: "/r/old", date: now.addingTimeInterval(-1000)))
        #expect(history.last?.directory == "/r/25")
        #expect(!history.entries.contains { $0.directory == "/r/old" })
    }

    @Test func historySurvivesARoundTripAndABrokenEntry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = DispatchHistory.fileURL(in: directory)
        #expect(DispatchHistory.load(from: url) == DispatchHistory())
        var history = DispatchHistory()
        history.record(.init(directory: "/r/a", name: "fix-login", model: nil, date: now))
        try history.save(to: url)
        #expect(DispatchHistory.load(from: url) == history)
        // The file holds no prompt text.
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("prompt"))

        try Data(#"{"entries": [{"directory": 7}, {"directory": "/r/b", "date": "2026-10-09T10:00:00Z"}, "junk"]}"#.utf8).write(to: url)
        #expect(DispatchHistory.load(from: url).entries.map(\.directory) == ["/r/b"])
        try Data("not json".utf8).write(to: url)
        #expect(DispatchHistory.load(from: url).entries.isEmpty)
    }

    @Test func recentUseCountsForMoreThanOldUse() {
        let used = history([("a", 0), ("b", 7), ("c", 28), ("c", 28), ("c", 28)])
        #expect(used.frecency(of: "/Users/u/code/a", now: now) == 1)
        #expect(used.frecency(of: "/Users/u/code/b", now: now) == 0.5)
        // Three uses a month ago are worth less than one today.
        #expect(abs(used.frecency(of: "/Users/u/code/c", now: now) - 0.1875) < 0.0001)
        #expect(used.frecency(of: "/Users/u/code/never", now: now) == 0)
    }

    @Test func withNothingTypedPinnedComeFirstThenMostUsedThenByName() {
        let repos = index(["alpha", "beta", "gamma", "delta", "omega"], pinned: ["omega"], sessions: ["delta"])
        let ranking = RepoRanking(history: history([("gamma", 1), ("gamma", 2), ("beta", 1)]), now: now, home: home)
        // omega is pinned; gamma was used twice, beta once; delta only has a session; alpha nothing.
        #expect(ranking.ranked(repos).map(\.name) == ["omega", "gamma", "beta", "delta", "alpha"])
        // No history at all: pinned, then by name.
        #expect(RepoRanking(now: now, home: home).ranked(index(["b", "a", "c"], pinned: ["c"])).map(\.name) == ["c", "a", "b"])
    }

    @Test func typedTextMatchesLettersInOrderAndUseBreaksNearTies() {
        let repos = index(["api-server", "api-client", "payments-api", "docs"])
        let plain = RepoRanking(now: now, home: home)
        // Equally good matches fall back to the name.
        #expect(plain.ranked(repos, query: "api").map(\.name) == ["api-client", "api-server", "payments-api"])
        // The one used lately moves ahead of an equally good match.
        let once = RepoRanking(history: history([("api-server", 0)]), now: now, home: home)
        #expect(once.ranked(repos, query: "api").map(\.name) == ["api-server", "api-client", "payments-api"])
        // Heavy use lifts a match at a word start over unused ones at the very start.
        let heavy = RepoRanking(history: history([("payments-api", 0), ("payments-api", 0), ("payments-api", 0)]), now: now, home: home)
        #expect(heavy.ranked(repos, query: "api").map(\.name) == ["payments-api", "api-client", "api-server"])
        // Letters in order, not together; nothing else matches.
        #expect(plain.ranked(repos, query: "asv").map(\.name) == ["api-server"])
        #expect(plain.ranked(repos, query: "zzz").isEmpty)
    }

    @Test func useNeverPutsAPoorMatchOverAGoodOne() {
        let repos = index(["docs", "old-docker-scripts"])
        // The long name matches "docs" only as scattered letters, however much it is used.
        let heavy = RepoRanking(history: history(Array(repeating: ("old-docker-scripts", daysAgo: 0), count: 20)), now: now, home: home)
        #expect(heavy.ranked(repos, query: "docs").map(\.name) == ["docs", "old-docker-scripts"])
        // Pinning does not either.
        let pinned = index(["docs", "old-docker-scripts"], pinned: ["old-docker-scripts"])
        #expect(RepoRanking(now: now, home: home).ranked(pinned, query: "docs").map(\.name) == ["docs", "old-docker-scripts"])
    }
}
