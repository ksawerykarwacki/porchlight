import Foundation
import Testing

@testable import PorchlightCore

@Suite struct SessionControlTests {
    func control(_ fake: FakeClaude, mode: String = "normal") -> SessionControl {
        SessionControl(claude: Fixtures.fakeClaude, environment: fake.environment(mode: mode))
    }

    @Test func stopAndRemoveRunExactlyTheDocumentedCommands() async throws {
        let fake = try FakeClaude()
        #expect(await control(fake).run(.stop, id: "4cb41c2a") == .done("stopped 4cb41c2a"))
        #expect(await control(fake).run(.remove, id: "4cb41c2a") == .done("removed 4cb41c2a"))
        // Folder, then arguments, for each call: nothing but the verb and the id.
        let recorded = try fake.recorded()
        #expect(recorded.count == 6)
        #expect(Array(recorded[1...2]) == ["stop", "4cb41c2a"])
        #expect(Array(recorded[4...5]) == ["rm", "4cb41c2a"])
    }

    @Test func aRefusalComesBackInTheCLIsOwnWords() async throws {
        let fake = try FakeClaude()
        let refused = await control(fake, mode: "rm-refused").run(.remove, id: "4cb41c2a")
        // The real CLI prints its refusal on standard output and exits 1.
        guard case .refused(let words) = refused else {
            Issue.record("expected a refusal, got \(refused)")
            return
        }
        #expect(words.hasPrefix("kept 4cb41c2a — its worktree is still at"))
        #expect(words.contains("2 unpushed commits") && words.hasSuffix("claude rm 4cb41c2a --discard-unpushed 1a2b3c4@wt-9"))
        #expect(SessionControl.overrides(in: words) == [.init(flag: "--discard-unpushed", value: "1a2b3c4@wt-9")])
        #expect(!refused.succeeded)
        #expect(await control(fake, mode: "stop-fail").run(.stop, id: "nope") == .refused("No background session matches nope"))
    }

    @Test func nothingThatDiscardsWorkIsPassedUnasked() async throws {
        let fake = try FakeClaude()
        // Refused once: it is not tried again another way.
        _ = await control(fake, mode: "rm-refused").run(.remove, id: "4cb41c2a")
        let recorded = try fake.recorded()
        #expect(recorded.filter { $0 == "rm" }.count == 1)
        #expect(!recorded.contains { $0.hasPrefix("--") })
        for action in SessionAction.allCases {
            let arguments = try #require(SessionControl.arguments(for: action, id: "4cb41c2a"))
            #expect(arguments.count == 2 && !arguments.contains { $0.hasPrefix("-") })
        }
    }

    @Test func onlyWhatTheCLINamedInItsRefusalCanBePassedBack() async throws {
        let refusal = "Not removed: worktree fix-login has 2 unpushed commits.\nTo discard them: claude rm 4cb41c2a --discard-unpushed 1a2b3c4@wt-9"
        let overrides = SessionControl.overrides(in: refusal)
        #expect(overrides == [SessionControl.Override(flag: "--discard-unpushed", value: "1a2b3c4@wt-9")])
        // Other shapes the CLI might use: an equals sign, a full stop after the value, both flags.
        #expect(SessionControl.overrides(in: "Run with --discard-unpushed=abc@wt.") == [.init(flag: "--discard-unpushed", value: "abc@wt")])
        #expect(SessionControl.overrides(in: "use --force-remove-worktree wt-3, or --discard-unpushed 9f@wt-3").map(\.flag) == ["--discard-unpushed", "--force-remove-worktree"])
        // Nothing named, or a value that is itself a flag: nothing to pass.
        #expect(SessionControl.overrides(in: "Not removed: the daemon is not running.").isEmpty)
        #expect(SessionControl.overrides(in: "--discard-unpushed --yes").isEmpty)
        #expect(SessionControl.overrides(in: "see --discard-unpushed").isEmpty)

        let fake = try FakeClaude()
        let outcome = await control(fake, mode: "rm-refused").run(.remove, id: "4cb41c2a", overrides: overrides)
        #expect(outcome == .done("removed 4cb41c2a"))
        #expect(Array(try fake.recorded().dropFirst()) == ["rm", "4cb41c2a", "--discard-unpushed", "1a2b3c4@wt-9"])

        // A stop takes no overrides, an unknown flag is never passed, and neither is a value that is a flag.
        #expect(SessionControl.arguments(for: .stop, id: "4cb41c2a", overrides: overrides) == nil)
        #expect(SessionControl.arguments(for: .remove, id: "4cb41c2a", overrides: [.init(flag: "--dangerously-skip-permissions", value: "x")]) == nil)
        #expect(SessionControl.arguments(for: .remove, id: "4cb41c2a", overrides: [.init(flag: "--discard-unpushed", value: "-x")]) == nil)
        #expect(ControlProblem(sessionID: "a", action: .stop, text: refusal).overrides.isEmpty)
        #expect(ControlProblem(sessionID: "a", action: .remove, text: refusal).overrides == overrides)
    }

    /// What `claude rm` 2.1.294 really printed for a throwaway session with an unpushed commit
    /// (lantern-probe, 2026-10-09), ids and all.
    @Test func theRealRefusalYieldsExactlyTheValueItNames() {
        let real = """
            kept ea30abec — its worktree is still at “/Users/u/git/lantern-probe/.claude/worktrees/porchlight-smoke-force”
              2 unpushed commits on “worktree-porchlight-smoke-force”: 51bcb07 “Smoke test: unpushed commit” and 1 more. They exist on no remote, so deleting the worktree would lose them.
              push them and run 'claude rm ea30abec' again, or discard the worktree and its commits: claude rm ea30abec --discard-unpushed 51bcb079f38a933f128b9651e56fb1ed0591a00b@24676e1500c1a8f606ae0c2aa570a8a6
            """
        let overrides = SessionControl.overrides(in: real)
        #expect(overrides == [.init(flag: "--discard-unpushed", value: "51bcb079f38a933f128b9651e56fb1ed0591a00b@24676e1500c1a8f606ae0c2aa570a8a6")])
        #expect(SessionControl.arguments(for: .remove, id: "ea30abec", overrides: overrides) == [
            "rm", "ea30abec", "--discard-unpushed", "51bcb079f38a933f128b9651e56fb1ed0591a00b@24676e1500c1a8f606ae0c2aa570a8a6",
        ])
    }

    @Test func theQuestionBeforeAForcedRemovalShowsTheRefusalAndSaysItIsFinal() {
        let refusal = "Not removed: worktree fix-login has 2 unpushed commits."
        let forced = PendingControl(
            sessionID: "a", name: "fix login", action: .remove, overrides: [.init(flag: "--discard-unpushed", value: "1@w")], refusal: refusal)
        #expect(forced.isForced && forced.verb == "Discard and remove")
        #expect(forced.question.contains("cannot be brought back") && forced.question.hasSuffix(refusal))
        let plain = PendingControl(sessionID: "a", name: "fix login", action: .remove, worktree: "Its worktree x is clean.")
        #expect(!plain.isForced && plain.verb == "Remove" && plain.question.hasSuffix("Its worktree x is clean."))
    }

    /// A real repository on disk, looked at with the real git.
    @Test func theWorktreeReportCountsWhatIsUncommittedAndWhatIsOnNoRemote() async throws {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("porchlight-worktree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let git = URL(fileURLWithPath: "/usr/bin/git")
        // Its own identity and no global configuration, so the test does not depend on the machine.
        let environment = ["HOME": base.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t", "PATH": "/usr/bin:/bin"]
        func run(_ arguments: String...) async throws {
            let result = try await CLIRunner().run(git, arguments, cwd: base, environment: environment)
            #expect(result.succeeded, "git \(arguments.joined(separator: " ")): \(result.stderr)")
        }
        try await run("init", "-q")
        try Data("one\n".utf8).write(to: base.appendingPathComponent("a.txt"))
        try await run("add", "a.txt")
        try await run("commit", "-q", "-m", "first")

        let inspector = WorktreeInspector()
        var report = try #require(await inspector.report(name: "fix", path: base.path))
        // One commit that is on no remote, nothing uncommitted.
        #expect(report.uncommitted == 0 && report.unpushed == 1 && !report.isClean)
        #expect(report.summary.contains("1 commit on no remote"))

        try Data("two\n".utf8).write(to: base.appendingPathComponent("b.txt"))
        try Data("changed\n".utf8).write(to: base.appendingPathComponent("a.txt"))
        report = try #require(await inspector.report(name: "fix", path: base.path))
        #expect(report.uncommitted == 2 && report.unpushed == 1)
        #expect(report.summary.contains("2 uncommitted files and 1 commit on no remote"))
        #expect(report.leftover == "Its worktree is still on disk with 2 uncommitted files: \(base.path)")

        // Not a folder, or not a repository: nothing to say.
        #expect(await inspector.report(name: "gone", path: base.path + "/missing") == nil)
        let plain = base.appendingPathComponent("plain-\(UUID().uuidString)")
        #expect(await inspector.report(name: "x", path: plain.path) == nil)
        // A stopped session reports its repository as its folder; the job details name the worktree.
        let stopped = try JSONDecoder().decode(JobState.self, from: Data(#"{"state": "stopped", "name": "n", "worktreePath": "\#(base.path)"}"#.utf8))
        let viaJob = Session(summary: SessionSummary(id: "s", name: "n", cwd: "/somewhere/else", kind: "background", state: SessionState(rawValue: "stopped")), job: stopped)
        #expect(await inspector.report(for: viaJob)?.uncommitted == 2)

        // A session that is not in a Claude worktree has none.
        let session = Session(summary: SessionSummary(id: "a", name: "n", cwd: base.path, kind: "background", state: .done))
        #expect(await inspector.report(for: session) == nil)
        #expect(WorktreeReport(name: "w", path: "/p", uncommitted: 0, unpushed: 0).summary.contains("will delete it too"))
    }

    @Test func anIdThatCouldBeAFlagNeverReachesTheCLI() async throws {
        let fake = try FakeClaude()
        for id in ["--discard-unpushed", "-x", "", "a b", "abc;rm", "../x", String(repeating: "a", count: 65)] {
            #expect(!SessionControl.isValidID(id), "\(id) was accepted")
            #expect(SessionControl.arguments(for: .remove, id: id) == nil)
            guard case .couldNotRun = await control(fake).run(.remove, id: id) else {
                Issue.record("\(id) was run")
                continue
            }
        }
        // Nothing was started, so the stand-in wrote no log.
        #expect(!FileManager.default.fileExists(atPath: fake.log.path))
        #expect(SessionControl.isValidID("4cb41c2a") && SessionControl.isValidID("fix-login-form"))
    }

    @Test func reportsAClaudeThatCannotBeRun() async {
        let outcome = await SessionControl(claude: URL(fileURLWithPath: "/nonexistent/claude")).run(.stop, id: "4cb41c2a")
        guard case .couldNotRun(let text) = outcome else {
            Issue.record("expected couldNotRun, got \(outcome)")
            return
        }
        #expect(text.hasPrefix("Could not run claude"))
    }

    @Test func theActionsApplyToBackgroundSessionsOnlyAndStopNotToFinishedOnes() {
        func session(_ kind: String?, _ state: SessionState) -> Session {
            Session(summary: SessionSummary(id: "a", name: "n", cwd: "/x", kind: kind, state: state))
        }
        #expect(SessionAction.stop.applies(to: session("background", .working)))
        #expect(SessionAction.stop.applies(to: session("background", .blocked)))
        #expect(!SessionAction.stop.applies(to: session("background", .done)))
        // What a stopped session reports: nothing to stop, still removable.
        #expect(!SessionAction.stop.applies(to: session("background", SessionState(rawValue: "stopped"))))
        #expect(SessionAction.remove.applies(to: session("background", SessionState(rawValue: "stopped"))))
        #expect(SessionAction.remove.applies(to: session("background", .done)))
        // A session in a terminal of its own, or of unknown kind, is left alone.
        for kind in ["interactive", nil] {
            #expect(!SessionAction.stop.applies(to: session(kind, .working)))
            #expect(!SessionAction.remove.applies(to: session(kind, .done)))
        }
        let row = InboxRow(session: session("background", .done))
        #expect(!row.canStop && row.canRemove)
    }

    @Test func theQuestionsSayWhatWillHappen() {
        #expect(SessionAction.stop.question(name: "fix login").contains("keeps its conversation"))
        #expect(SessionAction.remove.question(name: "fix login").contains("only if nothing in it would be lost"))
        #expect(SessionAction.stop.done(name: "fix login") == "Stopped fix login")
        #expect(SessionAction.remove.done(name: "fix login") == "Removed fix login")
    }
}
