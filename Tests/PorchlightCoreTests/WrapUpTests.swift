import Foundation
import Testing

@testable import PorchlightCore

private let conversation = "22222222-0000-4000-8000-000000000000"

private func staleSession(id: String = "22222222", conversation: String? = conversation, cwd: String = "/nowhere/app", worktree: String? = nil) throws -> Session {
    var job: JobState?
    if let worktree {
        let json = try JSONSerialization.data(withJSONObject: ["state": "blocked", "name": "rename the file", "worktreePath": worktree])
        job = try JSONDecoder().decode(JobState.self, from: json)
    }
    return Session(
        summary: SessionSummary(id: id, sessionId: conversation, name: "rename the file", cwd: cwd, kind: "background", state: .blocked), job: job)
}

/// The folder as a child process reports it: on macOS the temporary folder sits behind a link.
private func real(_ url: URL) -> URL {
    guard let resolved = realpath(url.path, nil) else { return url }
    defer { free(resolved) }
    return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
}

@Suite struct WrapUpTests {
    func summariser(_ fake: FakeClaude, mode: String = "normal") -> SessionSummariser {
        SessionSummariser(claude: Fixtures.fakeClaude, environment: fake.environment(mode: mode))
    }

    /// The calls the stand-in received, each as its folder followed by its arguments.
    func calls(_ fake: FakeClaude) throws -> [[String]] {
        let recorded = try fake.recorded()
        var calls: [[String]] = []
        for (index, word) in recorded.enumerated() where word == "--help" || word == "--print" {
            let end = recorded[(index + 1)...].firstIndex { $0 == "--help" || $0 == "--print" }.map { $0 - 1 } ?? recorded.count
            calls.append(Array(recorded[(index - 1)..<end]))
        }
        return calls
    }

    @Test func theSummaryIsAskedForWithExactlyTheDocumentedFlags() async throws {
        let fake = try FakeClaude()
        let folder = real(fake.scratch).path
        let result = await summariser(fake).summarise(try staleSession(cwd: folder), model: "haiku")
        let summary = try result.get()
        // The stand-in's colours are gone and its three parts are there.
        #expect(summary.hasPrefix("Doing: renaming the config file") && summary.contains("Stopped at:") && summary.hasSuffix("(haiku, \(conversation))"))

        let calls = try calls(fake)
        #expect(calls.count == 2 && calls[0].last == "--help")
        #expect(calls[1] == [
            folder, "--print", "--resume", conversation, "--fork-session", "--no-session-persistence", "--tools", "", "--model", "haiku", "--",
            WrapUp.prompt,
        ])
        // Nothing that lets the summariser act, skip a question or keep what it did.
        let arguments = try WrapUp.arguments(conversationID: conversation, model: "haiku")
        for forbidden in ["--dangerously-skip-permissions", "--permission-mode", "--bg", "--continue", "--allowedTools", "--add-dir"] {
            #expect(!arguments.contains(forbidden))
        }
        #expect(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] } == "")
        #expect(WrapUp.prompt.contains("Do not use any tools"))
    }

    @Test func theStandInItselfRefusesACallThatCouldChangeTheSession() async throws {
        // The control for the test above: drop any one safety flag and the stand-in exits 64.
        let fake = try FakeClaude()
        let good = try WrapUp.arguments(conversationID: conversation, model: "haiku")
        for flag in ["--fork-session", "--no-session-persistence"] {
            let result = try await CLIRunner().run(Fixtures.fakeClaude, good.filter { $0 != flag }, environment: fake.environment())
            #expect(result.exitCode == 64)
        }
        var withTools = good
        withTools[try #require(good.firstIndex(of: "--tools")) + 1] = "default"
        #expect(try await CLIRunner().run(Fixtures.fakeClaude, withTools, environment: fake.environment()).exitCode == 64)
        #expect(try await CLIRunner().run(Fixtures.fakeClaude, good, environment: fake.environment()).exitCode == 0)
    }

    @Test func aStoppedSessionIsResumedFromTheWorktreeItsJobNames() async throws {
        let fake = try FakeClaude()
        let root = real(fake.scratch)
        let worktree = root.appendingPathComponent(".claude/worktrees/rename")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        // The list reports the repository; the job knows the worktree.
        let session = try staleSession(cwd: root.path, worktree: worktree.path)
        #expect(WrapUp.folders(for: session) == [worktree.path, root.path])
        _ = try await summariser(fake).summarise(session, model: "haiku").get()
        #expect(try calls(fake)[1].first == worktree.path)

        // The worktree is gone: the repository is the next best place to look.
        let gone = try staleSession(cwd: root.path, worktree: root.appendingPathComponent("gone").path)
        let other = try FakeClaude()
        _ = try await SessionSummariser(claude: Fixtures.fakeClaude, environment: other.environment()).summarise(gone, model: "haiku").get()
        #expect(try calls(other)[1].first == root.path)
    }

    @Test func anIdOrModelThatCouldBeReadAsAFlagIsRefusedBeforeAnythingRuns() async throws {
        let fake = try FakeClaude()
        for bad in ["--dangerously-skip-permissions", "-x", "", "not a uuid", "22222222"] {
            #expect(throws: WrapUpFailure.noConversation) { try WrapUp.arguments(conversationID: bad, model: "haiku") }
        }
        for bad in ["--tools", "-m", "", "haiku --bg", "a;b", String(repeating: "a", count: 81)] {
            #expect(throws: WrapUpFailure.invalidModel(bad)) { try WrapUp.arguments(conversationID: conversation, model: bad) }
            #expect(await summariser(fake).summarise(try staleSession(), model: bad) == .failure(.invalidModel(bad)))
        }
        for good in ["haiku", "sonnet", "claude-haiku-5-5", "opus[1m]", "us.anthropic.claude-haiku-5-5-v1:0"] {
            #expect(WrapUp.isValidModel(good))
        }
        #expect(await summariser(fake).summarise(try staleSession(conversation: nil), model: "haiku") == .failure(.noConversation))
        #expect(await summariser(fake).summarise(try staleSession(conversation: "--bg"), model: "haiku") == .failure(.noConversation))
        // None of those reached the CLI at all.
        #expect(!FileManager.default.fileExists(atPath: fake.log.path))
    }

    @Test func aCLIWithoutOneOfTheFlagsIsNotAskedToSummarise() async throws {
        let fake = try FakeClaude()
        let result = await summariser(fake, mode: "old-help").summarise(try staleSession(), model: "haiku")
        #expect(result == .failure(.notSupported(missing: ["--resume", "--fork-session", "--no-session-persistence", "--tools", "--model"])))
        #expect(try !fake.recorded().contains("--print"))

        #expect(WrapUp.missingFlags(help: try Fixtures.text("claude-help.txt")).isEmpty)
        // A flag that only appears inside another's name or description is not the flag.
        let lookalikes = "  -p, --print  Print\n  --resume-all  x\n  --fork-session  x\n  --no-session-persistence  x\n  --toolset  see --tools\n  --model <model>  x\n"
        #expect(WrapUp.missingFlags(help: lookalikes) == ["--resume"])
        #expect(WrapUp.missingFlags(help: "") == WrapUp.requiredFlags)
    }

    @Test func aFailureComesBackInTheCLIsWordsAndAnEmptyAnswerIsNotASummary() async throws {
        let fake = try FakeClaude()
        let failed = await summariser(fake, mode: "print-fail").summarise(try staleSession(), model: "haiku")
        #expect(failed == .failure(.failed("No conversation found with session ID: \(conversation)")))
        #expect(WrapUpFailure.failed("No conversation found").message == "No conversation found")
        #expect(await summariser(fake, mode: "print-empty").summarise(try staleSession(), model: "haiku") == .failure(.empty))
        let missing = SessionSummariser(claude: URL(fileURLWithPath: "/nonexistent/claude"))
        #expect(await missing.summarise(try staleSession(), model: "haiku") == .failure(.couldNotRun("its help could not be read")))
    }

    @Test func wrappingUpKeepsTheSummaryAsANoteAndAFailureKeepsNothing() async throws {
        let fake = try FakeClaude()
        let archive = NotesArchive(directory: fake.scratch.appendingPathComponent("notes"))
        let now = Date(timeIntervalSince1970: 1_791_540_000)
        let folder = real(fake.scratch).path
        let note = try await summariser(fake).wrapUp(
            try staleSession(cwd: folder), model: "haiku", archive: archive, branch: "rename", pullRequest: "PR #12 is open", now: now
        ).get()
        #expect(note.id == "22222222" && note.sessionID == conversation && note.name == "rename the file" && note.model == "haiku")
        #expect(note.branch == "rename" && note.pullRequest == "PR #12 is open" && note.createdAt == now && note.directory == folder)
        #expect(note.resumeCommand == "cd \(ShellQuote.quote(folder)) && claude --resume \(conversation)")
        #expect(archive.note(for: "22222222") == note)

        let other = NotesArchive(directory: fake.scratch.appendingPathComponent("none"))
        let failed = await summariser(fake, mode: "print-fail").wrapUp(try staleSession(), model: "haiku", archive: other)
        #expect((try? failed.get()) == nil && other.all().isEmpty)
    }

    /// What haiku really answered for a throwaway session (lantern-probe, 2026-10-09): bold
    /// headings although plain text was asked for.
    @Test func theAnswerIsShownAsPlainText() {
        let real = "**Doing:** Creating `hello.txt` in a git worktree.\n\n**Stopped at:** The file is committed.\n\n\n**Worth keeping:** The rename decision is open.\n"
        #expect(WrapUp.tidy(real) == "Doing: Creating `hello.txt` in a git worktree.\n\nStopped at: The file is committed.\n\nWorth keeping: The rename decision is open.")
        #expect(WrapUp.tidy(" \n ") == "")
        #expect(WrapUp.prompt.contains("without Markdown"))
    }

    @Test func theModelSettingFallsBackToASmallOne() throws {
        #expect(WrapUpSettings().model == "haiku")
        let decode = { (json: String) in try JSONDecoder().decode(WrapUpSettings.self, from: Data(json.utf8)) }
        #expect(try decode("{}").model == "haiku")
        #expect(try decode(#"{"model":"sonnet"}"#).model == "sonnet")
        #expect(try decode(#"{"model":"--bg"}"#).model == "haiku")
        #expect(try decode(#"{"model":7}"#).model == "haiku")
        // Settings written before this existed still load, and the setting survives a round trip.
        #expect(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).wrapUp == nil)
        let settings = Settings(wrapUp: WrapUpSettings(model: "sonnet"))
        #expect(try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings)).wrapUp?.model == "sonnet")
    }
}

@Suite struct NotesArchiveTests {
    func scratch() throws -> NotesArchive {
        NotesArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-notes-\(UUID().uuidString)/notes"))
    }

    func note(_ id: String, _ summary: String, at seconds: TimeInterval, name: String = "task", repo: String = "app", branch: String? = nil) -> SessionNote {
        SessionNote(
            id: id, sessionID: conversation, name: name, repo: repo, directory: "/Users/u/code/my app", branch: branch, summary: summary,
            model: "haiku", createdAt: Date(timeIntervalSince1970: seconds))
    }

    @Test func notesAreKeptOnePerSessionAndReadBackNewestFirst() throws {
        let archive = try scratch()
        #expect(archive.all().isEmpty && archive.note(for: "aaaa1111") == nil)
        try archive.save(note("aaaa1111", "first", at: 100))
        try archive.save(note("bbbb2222", "second", at: 300))
        try archive.save(note("cccc3333", "third", at: 200))
        #expect(archive.all().map(\.id) == ["bbbb2222", "cccc3333", "aaaa1111"])
        // Wrapping the same session up again replaces its note.
        try archive.save(note("aaaa1111", "first, again", at: 400))
        #expect(archive.all().map(\.id) == ["aaaa1111", "bbbb2222", "cccc3333"])
        #expect(archive.note(for: "aaaa1111")?.summary == "first, again")
        #expect(try FileManager.default.contentsOfDirectory(atPath: archive.directory.path).sorted() == ["aaaa1111.json", "bbbb2222.json", "cccc3333.json"])
        #expect(archive.note(for: "aaaa1111")?.resumeCommand == "cd '/Users/u/code/my app' && claude --resume \(conversation)")
    }

    @Test func notesAreFoundByEveryWordInAnyOfTheirTexts() throws {
        let archive = try scratch()
        try archive.save(note("aaaa1111", "Doing: debugging the login redirect loop", at: 100, name: "login bug", repo: "web"))
        try archive.save(note("bbbb2222", "Doing: budget for October", at: 200, name: "finances", repo: "finance-infra", branch: "october"))
        #expect(archive.search("login").map(\.id) == ["aaaa1111"])
        #expect(archive.search("REDIRECT web").map(\.id) == ["aaaa1111"])
        #expect(archive.search("october").map(\.id) == ["bbbb2222"])
        #expect(archive.search("doing").count == 2 && archive.search("  ").count == 2)
        #expect(archive.search("login october").isEmpty && archive.search("kubernetes").isEmpty)
    }

    @Test func aBrokenNoteLosesOnlyItselfAndAnIdCannotLeaveTheFolder() throws {
        let archive = try scratch()
        try archive.save(note("aaaa1111", "good", at: 100))
        try Data("{not json".utf8).write(to: archive.directory.appendingPathComponent("bbbb2222.json"))
        try Data("stray".utf8).write(to: archive.directory.appendingPathComponent("README.txt"))
        #expect(archive.all().map(\.id) == ["aaaa1111"])
        #expect(archive.note(for: "bbbb2222") == nil)

        for bad in ["../escape", "a/b", "", "-x", "a b"] {
            #expect(throws: (any Error).self) { try archive.save(note(bad, "x", at: 1)) }
            #expect(archive.note(for: bad) == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: archive.directory.deletingLastPathComponent().appendingPathComponent("escape.json").path))
    }
}
