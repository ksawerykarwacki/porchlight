import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

/// What the model asked to be stopped or removed, and what to answer.
final class ControlProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCalls: [(SessionAction, String)] = []
    private var storedOutcome: ControlOutcome = .done("")

    var calls: [(SessionAction, String)] { lock.withLock { storedCalls } }
    var outcome: ControlOutcome {
        get { lock.withLock { storedOutcome } }
        set { lock.withLock { storedOutcome = newValue } }
    }

    func run(_ action: SessionAction, _ id: String) -> ControlOutcome {
        lock.withLock {
            storedCalls.append((action, id))
            return storedOutcome
        }
    }
}

@MainActor
@Suite struct InboxControlTests {
    actor Sessions {
        var rows: [SessionSummary]
        var reads = 0

        init(_ rows: [SessionSummary]) { self.rows = rows }

        func remove(_ id: String) { rows.removeAll { $0.id == id } }

        func read() -> AgentsSnapshot {
            reads += 1
            return AgentsSnapshot(sessions: rows, skipped: 0)
        }
    }

    static let rows = [
        SessionSummary(id: "aaaa1111", name: "fix login", cwd: "/Users/u/code/one", kind: "background", state: .working),
        SessionSummary(id: "bbbb2222", name: "old report", cwd: "/Users/u/code/two", kind: "background", state: .done),
        SessionSummary(id: "cccc3333", name: "in my terminal", cwd: "/Users/u/code/three", kind: "interactive", state: .working),
    ]

    func model() async throws -> (InboxModel, Sessions, ControlProbe) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessions = Sessions(Self.rows)
        let store = SessionStore(fetch: { await sessions.read() })
        let model = InboxModel(store: store, settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory))
        await store.refresh()
        model.apply(await store.snapshot)
        let probe = ControlProbe()
        model.runControl = { action, id in probe.run(action, id) }
        return (model, sessions, probe)
    }

    @Test func nothingHappensUntilItIsConfirmed() async throws {
        let (model, sessions, probe) = try await model()
        let readsBefore = await sessions.reads
        model.askControl(.stop, sessionID: "aaaa1111")
        #expect(model.pendingControl == PendingControl(sessionID: "aaaa1111", name: "fix login", action: .stop))
        #expect(probe.calls.isEmpty)

        model.cancelControl()
        #expect(model.pendingControl == nil && probe.calls.isEmpty)
        // Confirming with nothing asked does nothing either.
        #expect(await model.confirmControl() == nil)
        #expect(probe.calls.isEmpty)
        #expect(await sessions.reads == readsBefore)
    }

    @Test func confirmingRunsItOnceReadsTheSessionsAgainAndSaysSo() async throws {
        let (model, sessions, probe) = try await model()
        model.askControl(.remove, sessionID: "bbbb2222")
        // What claude rm does.
        await sessions.remove("bbbb2222")
        let outcome = await model.confirmControl()
        #expect(outcome == .done(""))
        #expect(probe.calls.count == 1 && probe.calls[0].0 == .remove && probe.calls[0].1 == "bbbb2222")
        #expect(model.pendingControl == nil && model.controlProblem == nil)
        #expect(model.notice == "Removed old report")
        // The row is gone without waiting for a poll.
        #expect(model.snapshot.sessions.map(\.id) == ["aaaa1111", "cccc3333"])
        #expect(await model.confirmControl() == nil)
        #expect(probe.calls.count == 1)
    }

    @Test func aRefusalStaysOnTheRowInTheCLIsWordsUntilDismissed() async throws {
        let (model, _, probe) = try await model()
        let words = "Not removed: worktree fix-login has 2 unpushed commits.\nTo discard them: claude rm bbbb2222 --discard-unpushed 1a2b3c4@wt-9"
        probe.outcome = .refused(words)
        model.askControl(.remove, sessionID: "bbbb2222")
        await model.confirmControl()
        #expect(model.controlProblem == ControlProblem(sessionID: "bbbb2222", action: .remove, text: words))
        #expect(model.controlProblem?.title == "Claude Code did not remove it")
        // Refused once: not tried again, and the session is still listed.
        #expect(probe.calls.count == 1)
        #expect(model.snapshot.sessions.contains { $0.id == "bbbb2222" })
        #expect(model.notice == nil)

        // Asking again clears the old refusal; dismissing does too.
        model.askControl(.remove, sessionID: "bbbb2222")
        #expect(model.controlProblem == nil)
        model.cancelControl()
        probe.outcome = .couldNotRun("The claude command was not found")
        model.askControl(.stop, sessionID: "aaaa1111")
        await model.confirmControl()
        #expect(model.controlProblem?.text == "The claude command was not found")
        model.dismissControlProblem()
        #expect(model.controlProblem == nil)
    }

    @Test func onlyWhatAppliesCanBeAskedFor() async throws {
        let (model, _, probe) = try await model()
        // A finished session cannot be stopped, a session in a terminal of its own is left alone,
        // and a session that is not there cannot be asked about.
        for (action, id) in [(SessionAction.stop, "bbbb2222"), (.stop, "cccc3333"), (.remove, "cccc3333"), (.remove, "zzzz9999")] {
            model.askControl(action, sessionID: id)
            #expect(model.pendingControl == nil, "\(action) \(id) was offered")
        }
        await model.confirmControl()
        #expect(probe.calls.isEmpty)
        #expect(model.rows.map { [$0.canStop, $0.canRemove] } == [[true, true], [false, false], [false, true]])
    }
}

@MainActor
@Suite struct PaletteControlTests {
    func harness() async throws -> (PaletteHarness, ControlProbe) {
        let harness = try PaletteHarness()
        harness.probe.rows = try PaletteSessions.rows()
        let probe = ControlProbe()
        harness.model.onControl = { pending in
            let outcome = probe.run(pending.action, pending.sessionID)
            if outcome.succeeded, pending.action == .remove {
                harness.probe.rows = harness.probe.rows.filter { $0.id != pending.sessionID }
            }
            return outcome
        }
        await harness.model.begin()
        return (harness, probe)
    }

    @Test func askingShowsTheQuestionAndReturnDoesIt() async throws {
        let (harness, probe) = try await harness()
        let model = harness.model
        model.moveSelection(by: 1)
        let row = try #require(model.selectedSession)
        #expect(row.id == "bbbb0002" && row.canStop && row.canRemove)
        model.askControlSelected(.remove)
        #expect(model.pendingControl == PendingControl(sessionID: "bbbb0002", name: "migrate billing tables", action: .remove))
        #expect(probe.calls.isEmpty)

        await model.confirmControl()
        #expect(probe.calls.count == 1 && probe.calls[0].0 == .remove && probe.calls[0].1 == "bbbb0002")
        #expect(model.pendingControl == nil)
        #expect(model.controlMessage == "Removed migrate billing tables")
        // The list was read again and the palette stayed open.
        #expect(!model.sessions.contains { $0.id == "bbbb0002" })
        #expect(harness.closed.values.isEmpty && harness.opened.values.isEmpty)
    }

    @Test func returnWithAQuestionUpConfirmsInsteadOfOpening() async throws {
        let (harness, probe) = try await harness()
        let model = harness.model
        var opened: [String] = []
        model.onOpenSession = { opened.append($0) }
        model.moveSelection(by: 1)
        model.askControlSelected(.stop)
        model.confirmFolder()
        for _ in 0..<200 where probe.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.calls.count == 1 && probe.calls[0].0 == .stop)
        #expect(opened.isEmpty && harness.closed.values.isEmpty)
    }

    @Test func escapeTypingOrMovingAwayDropsTheQuestionWithoutDoingIt() async throws {
        let (harness, probe) = try await harness()
        let model = harness.model
        model.moveSelection(by: 1)

        model.askControlSelected(.stop)
        model.escape()
        // Escape answered the question; it did not close the palette.
        #expect(model.pendingControl == nil && harness.closed.values.isEmpty)

        model.askControlSelected(.stop)
        model.moveSelection(by: 1)
        #expect(model.pendingControl == nil)

        model.moveSelection(by: -1)
        model.askControlSelected(.remove)
        model.setQuery("b")
        #expect(model.pendingControl == nil)

        await model.confirmControl()
        #expect(probe.calls.isEmpty)
        model.setQuery("")
        model.escape()
        #expect(harness.closed.values.count == 1)
    }

    @Test func aRefusalIsShownInTheCLIsWords() async throws {
        let (harness, probe) = try await harness()
        let model = harness.model
        probe.outcome = .refused("Not removed: worktree fix-login has 2 unpushed commits.")
        model.moveSelection(by: 1)
        model.askControlSelected(.remove)
        await model.confirmControl()
        #expect(model.controlMessage == "Not removed: worktree fix-login has 2 unpushed commits.")
        #expect(model.sessions.contains { $0.id == "bbbb0002" })
        #expect(probe.calls.count == 1)
    }

    @Test func theyAreOfferedOnlyWhereTheyApply() async throws {
        let (harness, probe) = try await harness()
        let model = harness.model
        // A finished session can be removed but not stopped.
        model.setQuery("old api cleanup")
        let done = try #require(model.selectedSession)
        #expect(done.kind == .done && !done.canStop && done.canRemove)
        model.askControlSelected(.stop)
        #expect(model.pendingControl == nil)
        model.askControlSelected(.remove)
        #expect(model.pendingControl?.action == .remove)
        model.escape()

        // A repository is neither.
        model.setQuery("website")
        model.moveSelection(by: 5)
        #expect(model.selectedRepo != nil)
        model.askControlSelected(.stop)
        model.askControlSelected(.remove)
        #expect(model.pendingControl == nil)

        // Nor once the palette has moved on to a prompt.
        model.confirmFolder()
        #expect(model.step == .prompt)
        model.askControlSelected(.remove)
        #expect(model.pendingControl == nil && probe.calls.isEmpty)
    }
}

@MainActor
@Suite struct ControlViewTests {
    func snapshot() -> StoreSnapshot {
        var snapshot = StoreSnapshot()
        snapshot.fetchedAt = Date(timeIntervalSince1970: 1_791_540_000)
        snapshot.sessions = InboxControlTests.rows.map { Session(summary: $0) }
        return snapshot
    }

    func height(_ actions: InboxActions) throws -> CGFloat {
        let view = InboxView(snapshot: snapshot(), now: Date(timeIntervalSince1970: 1_791_540_000), actions: actions, scrolls: false)
        let renderer = ImageRenderer(content: view.background(Color.white).environment(\.colorScheme, .light))
        return try #require(renderer.nsImage).size.height
    }

    @Test func theRowConcernedGrowsByItsQuestionAndOnlyThatRow() throws {
        let plain = try height(InboxActions())
        var asking = InboxActions()
        asking.pendingControl = PendingControl(sessionID: "aaaa1111", name: "fix login", action: .stop)
        let asked = try height(asking)
        // One line of question and a row of buttons.
        #expect(asked > plain + 50)

        // A question about a session that is not listed draws nothing.
        var elsewhere = InboxActions()
        elsewhere.pendingControl = PendingControl(sessionID: "zzzz9999", name: "gone", action: .stop)
        #expect(try height(elsewhere) == plain)
    }

    @Test func aRefusalDrawsItsTitleTheCLIsTextAndGrowsWithIt() throws {
        let plain = try height(InboxActions())
        var short = InboxActions()
        short.controlProblem = ControlProblem(sessionID: "bbbb2222", action: .remove, text: "Not removed.")
        var long = InboxActions()
        long.controlProblem = ControlProblem(
            sessionID: "bbbb2222", action: .remove,
            text: "Not removed: worktree fix-login has 2 unpushed commits.\nTo discard them: claude rm bbbb2222 --discard-unpushed 1a2b3c4@wt-9\nNothing was changed.")
        let shortHeight = try height(short)
        #expect(shortHeight > plain + 60)
        #expect(try height(long) > shortHeight + 20)
    }

    @Test func theButtonsCallTheirActions() {
        var calls: [String] = []
        var actions = InboxActions()
        actions.askControl = { action, id in calls.append("ask \(action.rawValue) \(id)") }
        actions.confirmControl = { calls.append("confirm") }
        actions.cancelControl = { calls.append("cancel") }
        actions.dismissControlProblem = { calls.append("dismiss") }
        actions.askControl(.remove, "bbbb2222")
        actions.confirmControl()
        actions.cancelControl()
        actions.dismissControlProblem()
        #expect(calls == ["ask remove bbbb2222", "confirm", "cancel", "dismiss"])
    }
}
