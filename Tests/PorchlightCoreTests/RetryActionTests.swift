import Foundation
import Testing

@testable import PorchlightCore

/// Stands in for the terminal: runs the command it is handed against the fake claude, the way a
/// terminal tab would, so what Retry leads to shows up in the fake's argv log.
actor FakeTerminal: TerminalLauncher {
    let fake: FakeClaude
    let outcome: LaunchOutcome?
    private(set) var opened: [TerminalCommand] = []

    /// - Parameter outcome: answer with this instead of running anything, to play a terminal
    ///   that could not be driven.
    init(_ fake: FakeClaude, outcome: LaunchOutcome? = nil) {
        self.fake = fake
        self.outcome = outcome
    }

    func open(_ command: TerminalCommand) async -> LaunchOutcome {
        opened.append(command)
        if let outcome { return outcome }
        let arguments = Array(command.arguments.dropFirst())
        _ = try? await CLIRunner().run(
            URL(fileURLWithPath: command.arguments[0]), arguments,
            cwd: command.cwd.map { URL(fileURLWithPath: $0) }, environment: fake.environment())
        return .opened(terminal: "Fake Terminal")
    }
}

/// Collects what would have gone to the clipboard.
actor Clipboard {
    private(set) var copies: [String] = []
    func copy(_ text: String) -> Bool {
        copies.append(text)
        return true
    }
}

@Suite struct RetryActionTests {
    let limit = "You've hit your session limit · resets 3:45pm"
    let claude = Fixtures.fakeClaude.path

    @Test func thePlanIsToAttachAndHaveContinueReadyToSend() throws {
        let failed = try session("f0f0f0f0", needs: limit, cwd: "/Users/u/code/alpha/.claude/worktrees/fix-it")
        let plan = try #require(RetryPlan(session: failed, claude: "/opt/bin/claude"))
        // The documented attach, nothing else: no respawn, no prompt on the command line.
        #expect(plan.command.arguments == ["/opt/bin/claude", "attach", "f0f0f0f0"])
        #expect(plan.command == TerminalCommand.attach(to: failed, claude: "/opt/bin/claude"))
        #expect(plan.command.cwd == "/Users/u/code/alpha")
        #expect(plan.command.sessionID == "f0f0f0f0")
        #expect(plan.resend == "continue")

        // The line to resend is a setting too.
        let custom = TransientErrors(resend: "please try that again")
        #expect(RetryPlan(session: failed, settings: custom, claude: claude)?.resend == "please try that again")
    }

    @Test func thereIsNoPlanForASessionThatIsNotWaitingOnAFailure() throws {
        let others: [Session] = [
            try session(needs: "Which of the two timeouts should I raise?"),
            try session(needs: "should I raise the rate limit to 100?"),
            try session(needs: "answer: \(limit)? (Wait · Switch)"),
            try session(needs: "approve Bash: echo \"\(limit)\""),
            try session(needs: limit, questions: true),
            try session(state: .working, needs: limit),
            try session(state: .done, needs: limit),
            waiting("plain", since: noon),
        ]
        for other in others {
            #expect(RetryPlan(session: other, claude: claude) == nil, "\(String(describing: other.job?.needs))")
        }
        // And none when the user has turned detection off.
        #expect(RetryPlan(session: try session(needs: limit), settings: TransientErrors(patterns: []), claude: claude) == nil)
    }

    @Test func retryRunsAttachForThatSessionAndThenCopiesTheLine() async throws {
        let fake = try FakeClaude()
        let terminal = FakeTerminal(fake)
        let clipboard = Clipboard()
        let failed = try session("f0f0f0f0", needs: limit, cwd: fake.scratch.path)

        let outcome = await Retry.run(session: failed, claude: claude, launcher: terminal) { await clipboard.copy($0) }

        #expect(outcome == .launched(.opened(terminal: "Fake Terminal"), resendCopied: true))
        // What the fake claude was started with: its working directory, then the arguments.
        let recorded = try fake.recorded()
        #expect(recorded.count == 3)
        #expect(recorded.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == fake.scratch.resolvingSymlinksInPath())
        #expect(Array(recorded.dropFirst()) == ["attach", "f0f0f0f0"])
        #expect(await terminal.opened.count == 1)
        #expect(await clipboard.copies == ["continue"])
    }

    @Test func retryNeverRunsForASessionThatIsNotWaitingOnAFailure() async throws {
        let fake = try FakeClaude()
        let terminal = FakeTerminal(fake)
        let clipboard = Clipboard()
        let others: [Session] = [
            try session("a0a0a0a0", needs: "should I raise the rate limit to 100?", cwd: fake.scratch.path),
            try session("b0b0b0b0", needs: "approve Bash: echo \"\(limit)\"", cwd: fake.scratch.path),
            try session("c0c0c0c0", needs: "answer: \(limit)? (Wait · Switch)", cwd: fake.scratch.path),
            try session("d0d0d0d0", state: .working, needs: limit, cwd: fake.scratch.path),
            try session("e0e0e0e0", state: .done, needs: limit, cwd: fake.scratch.path),
        ]
        for other in others {
            let outcome = await Retry.run(session: other, claude: claude, launcher: terminal) { await clipboard.copy($0) }
            #expect(outcome == .notRetryable, "\(other.id)")
        }
        // Detection turned off: not even a real failure is retried.
        let off = await Retry.run(
            session: try session(needs: limit, cwd: fake.scratch.path), settings: TransientErrors(patterns: []), claude: claude,
            launcher: terminal
        ) { await clipboard.copy($0) }
        #expect(off == .notRetryable)

        // The terminal was never asked, claude never ran, the clipboard was never touched.
        #expect(await terminal.opened.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fake.log.path))
        #expect(await clipboard.copies.isEmpty)
    }

    @Test func theLineIsNotCopiedOverACommandTheTerminalFallbackCopied() async throws {
        let fake = try FakeClaude()
        let failed = try session("f0f0f0f0", needs: limit, cwd: fake.scratch.path)
        let clipboard = Clipboard()

        // The launcher could not drive a terminal and put the command on the clipboard itself.
        let fallback = LaunchOutcome.copiedToClipboard(reason: "no terminal found")
        let copied = await Retry.run(session: failed, claude: claude, launcher: FakeTerminal(fake, outcome: fallback)) { await clipboard.copy($0) }
        #expect(copied == .launched(fallback, resendCopied: false))

        let broken = await Retry.run(session: failed, claude: claude, launcher: FakeTerminal(fake, outcome: .failed("boom"))) { await clipboard.copy($0) }
        #expect(broken == .launched(.failed("boom"), resendCopied: false))
        #expect(await clipboard.copies.isEmpty)

        // A terminal that already shows the session still gets the line.
        let already = LaunchOutcome.alreadyOpen(terminal: "Warp")
        let focused = await Retry.run(session: failed, claude: claude, launcher: FakeTerminal(fake, outcome: already)) { await clipboard.copy($0) }
        #expect(focused == .launched(already, resendCopied: true))
        #expect(await clipboard.copies == ["continue"])
        // A clipboard that refuses is reported, not hidden.
        let refused = await Retry.run(session: failed, claude: claude, launcher: FakeTerminal(fake, outcome: already)) { _ in false }
        #expect(refused == .launched(already, resendCopied: false))
    }
}
