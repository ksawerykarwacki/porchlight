import Foundation
import Testing

@testable import PorchlightCore

enum Fixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let fakeClaude = directory.appendingPathComponent("fake-claude")
    static let jobs = directory.appendingPathComponent("jobs")

    static func text(_ name: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
}

/// Runs the fake CLI in a scratch directory and reads back what it was called with.
struct FakeClaude {
    let scratch: URL
    let log: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        log = scratch.appendingPathComponent("argv.log")
    }

    func environment(mode: String = "normal") -> [String: String] {
        ["PATH": "/usr/bin:/bin", "FAKE_CLAUDE_LOG": log.path, "FAKE_CLAUDE_MODE": mode]
    }

    /// Working directory followed by argv, exactly as the process received them.
    func recorded() throws -> [String] {
        let data = try Data(contentsOf: log)
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }
}

@Suite struct ANSITests {
    @Test func stripsColoursAndCursorMoves() {
        #expect(ANSI.strip("\u{1B}[36m4cb41c2a\u{1B}[39m") == "4cb41c2a")
        #expect(ANSI.strip("\u{1B}7\u{1B}8\u{1B}[2J\u{1B}[Hhello\u{1B}[38;2;215;119;87m!") == "hello!")
        #expect(ANSI.strip("\u{1B}]0;title\u{07}body") == "body")
        #expect(ANSI.strip("plain · text") == "plain · text")
    }
}

@Suite struct DispatchOutputTests {
    @Test func readsTheIdFromColouredOutput() {
        let stdout = "backgrounded · \u{1B}[36m4cb41c2a\u{1B}[39m · lantern-probe-worktree\n\u{1B}[2m  claude agents             list sessions\u{1B}[22m\n"
        #expect(DispatchOutput.sessionID(from: stdout) == "4cb41c2a")
        #expect(DispatchOutput.sessionID(from: "nothing useful") == nil)
    }

    @Test func recognisesTheTrustRefusal() {
        let stderr = "Workspace not trusted. Run `claude` in /Users/u/code/new-repo once and accept the trust prompt, then retry.\n"
        #expect(DispatchFailure(stderr: stderr) == .workspaceNotTrusted(path: "/Users/u/code/new-repo"))
        #expect(DispatchFailure(stderr: "boom\n") == .other("boom"))
    }
}

@Suite struct SessionSummaryTests {
    @Test func decodesEveryUsableRowAndCountsTheRest() throws {
        let snapshot = try AgentsCLISource.decode(Fixtures.text("agents-all.json"))
        #expect(snapshot.sessions.map(\.id) == ["11111111", "22222222", "33333333", "44444444", "55555555", "66666666"])
        #expect(snapshot.skipped == 2)
    }

    @Test func keepsStateIndependentOfStatus() throws {
        let sessions = try AgentsCLISource.decode(Fixtures.text("agents-all.json")).sessions
        let blockedButBusy = try #require(sessions.first { $0.id == "11111111" })
        #expect(blockedButBusy.state == .blocked)
        #expect(blockedButBusy.status == "busy")
        #expect(blockedButBusy.waitingFor == nil)
        #expect(sessions.first { $0.id == "55555555" }?.waitingFor == "permission prompt")
        #expect(sessions.first { $0.id == "22222222" }?.waitingFor == "input needed")
    }

    @Test func toleratesUnknownStatesAndBadFields() throws {
        let sessions = try AgentsCLISource.decode(Fixtures.text("agents-all.json")).sessions
        let odd = try #require(sessions.first { $0.id == "66666666" })
        #expect(odd.state == .unknown("hibernating"))
        #expect(odd.startedAt == nil)
        #expect(odd.pid == nil)
        let normal = try #require(sessions.first { $0.id == "33333333" })
        #expect(normal.startedAt == Date(timeIntervalSince1970: 1791479629.658))
    }

    @Test func rejectsOutputThatIsNotAnArray() {
        #expect(throws: AgentsCLIError.invalidJSON) { try AgentsCLISource.decode("{not json") }
    }
}

@Suite struct JobStateTests {
    let source = JobStateSource(jobsDirectory: Fixtures.jobs)

    @Test func parsesNeedsByPrefix() {
        #expect(Needs(parsing: "answer: Rename it? (a · b)") == .question("Rename it? (a · b)"))
        #expect(Needs(parsing: "approve Bash: echo hi > f && git commit -m \"x: y\"") == .approval(tool: "Bash", detail: "echo hi > f && git commit -m \"x: y\""))
        #expect(Needs(parsing: "Which timeout?") == .other("Which timeout?"))
    }

    @Test func readsAnOlderSchemaWithASuggestedReply() throws {
        let job = try #require(source.load(id: "11111111"))
        #expect(job.cliVersion == "2.1.283")
        #expect(job.needs == .other("Which of the two timeouts should I raise?"))
        #expect(job.suggestedReply == "Raise the network timeout to 30s.")
        #expect(job.updatedAt == Date(timeIntervalSince1970: 1_791_311_050))
        #expect(job.children.isEmpty)
    }

    @Test func readsAStructuredQuestionAndTreatsNullsAsAbsent() throws {
        let job = try #require(source.load(id: "22222222"))
        #expect(job.state == "working")
        #expect(job.tempo == "blocked")
        #expect(job.detail == nil)
        #expect(job.suggestedReply == nil)
        #expect(job.children.isEmpty)
        #expect(job.questions.count == 1)
        #expect(job.questions[0].options.map(\.label) == ["greeting.txt (Recommended)", "salute.txt"])
    }

    @Test func readsWorktreeFieldsAndApprovals() throws {
        let job = try #require(source.load(id: "55555555"))
        #expect(job.worktreeBranch == "worktree-add-hello")
        #expect(job.cwd == "/Users/u/code/probe")
        #expect(job.children.first?.kind == "pr")
        guard case .approval(let tool, _) = job.needs else {
            Issue.record("expected an approval")
            return
        }
        #expect(tool == "Bash")
    }

    @Test func givesNoEnrichmentForMissingOrUnrecognisedFiles() {
        #expect(source.load(id: "66666666") == nil)
        #expect(source.load(id: "99999999") == nil)
        #expect(source.load(id: "../11111111") == nil)
    }
}

@Suite struct SessionTests {
    @Test func derivesTheRepoFromAWorktreePath() {
        let inWorktree = RepoLocation(cwd: "/Users/u/code/probe/.claude/worktrees/add-hello")
        #expect(inWorktree.repoName == "probe")
        #expect(inWorktree.worktreeName == "add-hello")
        let plain = RepoLocation(cwd: "/Users/u/code/alpha")
        #expect(plain.repoName == "alpha")
        #expect(plain.worktreeName == nil)
    }

    @Test func onlyBlockedSessionsExposeWhatTheyNeed() throws {
        let summaries = try AgentsCLISource.decode(Fixtures.text("agents-all.json")).sessions
        let sessions = JobStateSource(jobsDirectory: Fixtures.jobs).enrich(summaries)
        #expect(sessions.filter(\.needsHuman).map(\.id) == ["11111111", "22222222", "55555555"])
        let working = try #require(sessions.first { $0.id == "33333333" })
        #expect(working.needs == nil)
        #expect(working.job == nil)
    }

    @Test func reportsStatusAsJSONWithoutSensitiveFields() throws {
        let summaries = try AgentsCLISource.decode(Fixtures.text("agents-all.json"))
        let sessions = JobStateSource(jobsDirectory: Fixtures.jobs).enrich(summaries.sessions)
        let json = try StatusReport(sessions: sessions, skippedRows: summaries.skipped).json()
        #expect(!json.contains("MUST-NEVER-BE-READ"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["waiting"] as? Int == 3)
        #expect(object["skippedRows"] as? Int == 2)
        let rows = try #require(object["sessions"] as? [[String: Any]])
        let probe = try #require(rows.first { $0["id"] as? String == "55555555" })
        #expect(probe["repo"] as? String == "probe")
        #expect(probe["worktree"] as? String == "add-hello")
        #expect((probe["needs"] as? [String: Any])?["kind"] as? String == "approval")
        let question = try #require(rows.first { $0["id"] as? String == "22222222" })
        #expect((question["options"] as? [[String: Any]])?.count == 2)
    }
}

@Suite struct ClaudeLocatorTests {
    @Test func prefersTheOverrideThenPathThenKnownLocations() {
        let locator = ClaudeLocator(
            override: "/custom/claude",
            environment: ["PATH": "/usr/bin:/opt/tools"],
            homeDirectory: "/Users/u",
            isExecutable: { $0 == "/Users/u/.local/bin/claude" || $0 == "/opt/homebrew/bin/claude" }
        )
        #expect(locator.candidates().prefix(3) == ["/custom/claude", "/usr/bin/claude", "/opt/tools/claude"])
        #expect(locator.locate()?.path == "/Users/u/.local/bin/claude")
    }

    @Test func findsNothingWhenNothingIsInstalled() {
        let locator = ClaudeLocator(environment: [:], homeDirectory: "/Users/u", isExecutable: { _ in false })
        #expect(locator.locate() == nil)
    }

    @Test func comparesVersions() throws {
        let version = try #require(CLIVersion(parsing: "2.1.294 (Claude Code)\n"))
        #expect(version.description == "2.1.294")
        #expect(version > CLIVersion([2, 1, 283]))
        #expect(version < CLIVersion([2, 2]))
        #expect(CLIVersion([2, 1]) == CLIVersion([2, 1, 0]))
        #expect(CLIVersion(parsing: "no version here") == nil)
    }
}

@Suite struct CLIRunnerTests {
    @Test func passesArgumentsVerbatimAndSetsTheWorkingDirectory() async throws {
        let fake = try FakeClaude()
        let prompt = "fix it; rm -rf \"$HOME\"\nsecond line `whoami`"
        let result = try await CLIRunner().run(
            Fixtures.fakeClaude, ["--bg", "-n", "my name", prompt], cwd: fake.scratch, environment: fake.environment())
        #expect(result.succeeded)
        #expect(DispatchOutput.sessionID(from: result.stdout) == "4cb41c2a")
        let recorded = try fake.recorded()
        #expect(recorded.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == fake.scratch.resolvingSymlinksInPath())
        #expect(Array(recorded.dropFirst()) == ["--bg", "-n", "my name", prompt])
    }

    @Test func capturesStderrAndExitCodeOnRefusal() async throws {
        let fake = try FakeClaude()
        let result = try await CLIRunner().run(
            Fixtures.fakeClaude, ["--bg", "hello"], cwd: fake.scratch, environment: fake.environment(mode: "untrusted"))
        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        guard case .workspaceNotTrusted(let path) = DispatchFailure(stderr: result.stderr) else {
            Issue.record("expected the trust refusal")
            return
        }
        #expect(path?.hasSuffix(fake.scratch.lastPathComponent) == true)
    }

    @Test func timesOutAHangingCommand() async throws {
        let fake = try FakeClaude()
        let started = Date()
        await #expect(throws: CLIError.timedOut(after: 0.5)) {
            try await CLIRunner().run(Fixtures.fakeClaude, ["agents"], environment: fake.environment(mode: "hang"), timeout: 0.5)
        }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func reportsAnExecutableThatCannotBeLaunched() async {
        await #expect(throws: CLIError.self) {
            try await CLIRunner().run(URL(fileURLWithPath: "/nonexistent/claude"), ["--version"])
        }
    }

    @Test func readsTheVersion() async throws {
        let fake = try FakeClaude()
        let result = try await CLIRunner().run(Fixtures.fakeClaude, ["--version"], environment: fake.environment())
        #expect(CLIVersion(parsing: result.stdout) == CLIVersion([2, 1, 294]))
    }
}

@Suite struct AgentsCLISourceTests {
    @Test func takesASnapshotThroughTheCLI() async throws {
        let snapshot = try await AgentsCLISource(executable: Fixtures.fakeClaude).snapshot()
        #expect(snapshot.sessions.count == 6)
    }
}

@Suite struct ArchitectureTests {
    /// The core must stay usable by non-Apple frontends: Foundation only.
    @Test func coreImportsNoUIOrAppleOnlyFrameworks() throws {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PorchlightCore")
        let files = try FileManager.default.contentsOfDirectory(at: core, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(separator: "\n") where line.hasPrefix("import ") {
                #expect(line == "import Foundation", "\(file.lastPathComponent): \(line)")
            }
        }
    }
}
