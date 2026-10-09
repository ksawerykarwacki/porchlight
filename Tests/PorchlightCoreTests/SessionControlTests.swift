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
        #expect(refused == .refused("Not removed: worktree fix-login has 2 unpushed commits.\nTo discard them: claude rm 4cb41c2a --discard-unpushed 1a2b3c4@wt-9"))
        #expect(!refused.succeeded)
        #expect(await control(fake, mode: "stop-fail").run(.stop, id: "nope") == .refused("No background session matches nope"))
    }

    @Test func nothingThatDiscardsWorkIsEverPassed() async throws {
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
        // The source has no way to say them at all.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/PorchlightCore/SessionControl.swift"), encoding: .utf8)
        #expect(!source.contains("\"--discard-unpushed\"") && !source.contains("\"--force-remove-worktree\""))
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
