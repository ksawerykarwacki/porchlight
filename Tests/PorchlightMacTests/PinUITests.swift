import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

@MainActor
@Suite struct InboxPinTests {
    static let now = Date(timeIntervalSince1970: 1_791_540_000)

    static let rows = [
        SessionSummary(id: "wait0001", name: "review", cwd: "/Users/u/code/review", kind: "background", state: .blocked),
        SessionSummary(id: "wait0002", name: "finance", cwd: "/Users/u/code/finance", kind: "background", state: .blocked),
        SessionSummary(id: "done0003", name: "debug notes", cwd: "/Users/u/code/debug", kind: "background", state: .done),
    ]

    func model(in directory: URL? = nil) throws -> (InboxModel, URL) {
        let directory = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-inbox-pins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixed = Self.now
        let model = InboxModel(settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory), clock: { fixed })
        var snapshot = StoreSnapshot()
        snapshot.fetchedAt = Self.now
        snapshot.sessions = Self.rows.map { Session(summary: $0, observedBlockedSince: $0.state == .blocked ? Self.now - 600 : nil) }
        model.apply(snapshot)
        model.inspectWorktree = { _ in nil }
        return (model, directory)
    }

    @Test func pinningGroupsTheSessionAtTheTopAndSurvivesARestart() throws {
        let (model, directory) = try model()
        #expect(model.rows.first?.isPinned == false)
        model.togglePin(sessionID: "done0003")
        #expect(model.notice == "Pinned debug notes")
        #expect(model.rows.first?.id == "done0003" && model.rows.first?.isPinned == true)
        // The file is next to the other state, in the folder the test gave.
        #expect(Pins.load(from: Pins.fileURL(in: directory)).isPinned("done0003"))

        let (relaunched, _) = try self.model(in: directory)
        #expect(relaunched.pins.isPinned("done0003"))
        #expect(relaunched.rows.first?.id == "done0003")

        relaunched.togglePin(sessionID: "done0003")
        #expect(relaunched.notice == "Unpinned debug notes")
        #expect(!relaunched.rows.contains { $0.isPinned })
        #expect(Pins.load(from: Pins.fileURL(in: directory)) == Pins())
        // A session that is not there cannot be pinned.
        relaunched.togglePin(sessionID: "gone9999")
        #expect(relaunched.pins == Pins())
    }

    @Test func aQuietPinTakesTheSessionOutOfTheLanternAndOnlyAPinCanBeQuiet() throws {
        let (model, _) = try model()
        #expect(model.status == .waiting(count: 2))
        // Not pinned: nothing to quiet.
        model.setPinQuiet(sessionID: "wait0002", true)
        #expect(model.pins == Pins() && model.status == .waiting(count: 2))

        model.togglePin(sessionID: "wait0002")
        #expect(model.status == .waiting(count: 2))
        model.setPinQuiet(sessionID: "wait0002", true)
        #expect(model.status == .waiting(count: 1))
        #expect(model.notice == "finance will not remind you while it is pinned")
        #expect(model.rows.first { $0.id == "wait0002" }?.isQuiet == true)
        model.setPinQuiet(sessionID: "wait0002", false)
        #expect(model.status == .waiting(count: 2))
    }

    @Test func aPinnedSessionCannotBeAskedToBeRemovedAndPinningDropsAPendingRemoval() throws {
        let (model, _) = try model()
        model.askControl(.remove, sessionID: "done0003")
        #expect(model.pendingControl?.action == .remove)
        // Pinning while the question is up answers it: no.
        model.togglePin(sessionID: "done0003")
        #expect(model.pendingControl == nil)
        model.askControl(.remove, sessionID: "done0003")
        #expect(model.pendingControl == nil)
        #expect(model.rows.first { $0.id == "done0003" }?.canRemove == false)
        // Stopping a pinned session that runs is still allowed.
        model.togglePin(sessionID: "wait0001")
        model.askControl(.stop, sessionID: "wait0001")
        #expect(model.pendingControl?.action == .stop)
    }

    @Test func aClickOnTheDailySummaryShowsTheListOfSessions() throws {
        let (model, _) = try model()
        var shown = 0
        model.showInbox = { shown += 1 }
        model.handle(.showInbox)
        #expect(shown == 1)
    }

    @Test func thePinnedSectionIsDrawnWithItsHeading() throws {
        func height(_ pins: Pins) throws -> CGFloat {
            var actions = InboxActions()
            actions.pins = pins
            var snapshot = StoreSnapshot()
            snapshot.fetchedAt = Self.now
            // The finished session is old: only a pin puts it on screen.
            snapshot.sessions = Self.rows.map {
                Session(summary: SessionSummary(id: $0.id, name: $0.name, cwd: $0.cwd, kind: $0.kind, state: $0.state, startedAt: Self.now - 40 * 86400))
            }
            let view = InboxView(snapshot: snapshot, now: Self.now, actions: actions, scrolls: false)
            return try #require(ImageRenderer(content: view.background(Color.white)).nsImage).size.height
        }
        var pins = Pins()
        pins.pin("done0003", now: Self.now)
        // One more row and one more heading.
        #expect(try height(pins) > (try height(Pins())) + 50)
    }
}

@MainActor
@Suite struct PalettePinTests {
    @Test func pinnedSessionsComeFirstWhateverTheirState() throws {
        let rows = try PaletteSessions.rows()
        let done = try #require(rows.first { $0.kind == .done })
        let working = try #require(rows.last { $0.kind == .working })
        func pinned(_ row: InboxRow) -> InboxRow {
            InboxRow(
                session: Session(summary: SessionSummary(id: row.id, name: row.title, cwd: "/Users/u/code/x", kind: "background", state: row.kind == .done ? .done : .working)),
                pin: Pin(since: PaletteHarness.now), now: PaletteHarness.now)
        }
        let withPins = [pinned(done), pinned(working)] + rows.filter { $0.id != done.id && $0.id != working.id }
        let offered = PaletteModel.sessions(withPins, matching: "")
        #expect(offered.prefix(2).map(\.id) == [done.id, working.id])
        // Then the waiting ones, then working ones up to the limit; no other finished session.
        #expect(offered.dropFirst(2).prefix(2).allSatisfy { $0.kind.needsUser })
        #expect(offered.filter { $0.kind == .done }.map(\.id) == [done.id])
        #expect(offered.count == 2 + 2 + PaletteModel.workingSessionsShown)
    }

    @Test func thePinKeyTogglesThePinOnTheSelectedSessionAndStaysOnIt() async throws {
        let harness = try PaletteHarness()
        harness.probe.rows = try PaletteSessions.rows()
        var toggled: [String] = []
        harness.model.onTogglePin = { id in
            toggled.append(id)
            // What the inbox does: the list comes back with the session pinned, first.
            let rows = harness.probe.rows
            guard let row = rows.first(where: { $0.id == id }) else { return }
            let pinned = InboxRow(
                session: Session(summary: SessionSummary(id: row.id, name: row.title, cwd: "/Users/u/code/x", kind: "background", state: .working)),
                pin: Pin(since: PaletteHarness.now), now: PaletteHarness.now)
            harness.probe.rows = [pinned] + rows.filter { $0.id != id }
        }
        await harness.model.begin()
        let model = harness.model
        model.moveSelection(by: 3)
        let chosen = try #require(model.selectedSession)
        #expect(!chosen.isPinned)
        await model.togglePinSelected()
        #expect(toggled == [chosen.id])
        // It moved to the top of the list, and the selection moved with it.
        #expect(model.selection == 0 && model.selectedSession?.id == chosen.id && model.selectedSession?.isPinned == true)
        #expect(harness.closed.values.isEmpty)

        // A repository has no pin here, and neither has the prompt step.
        model.moveSelection(by: 100)
        #expect(model.selectedRepo != nil)
        await model.togglePinSelected()
        #expect(toggled.count == 1)
    }

    @Test func aPinnedSessionIsNotOfferedForRemovalInThePalette() async throws {
        let harness = try PaletteHarness()
        let rows = try PaletteSessions.rows()
        let target = try #require(rows.first { $0.id == "bbbb0002" })
        let pinned = InboxRow(
            session: Session(summary: SessionSummary(id: target.id, name: target.title, cwd: "/Users/u/code/billing", kind: "background", state: .blocked), observedBlockedSince: PaletteHarness.now - 600),
            pin: Pin(since: PaletteHarness.now), now: PaletteHarness.now)
        harness.probe.rows = [pinned] + rows.filter { $0.id != target.id }
        await harness.model.begin()
        #expect(harness.model.selectedSession?.id == "bbbb0002")
        harness.model.askControlSelected(.remove)
        #expect(harness.model.pendingControl == nil)
        harness.model.askControlSelected(.stop)
        #expect(harness.model.pendingControl?.action == .stop)
    }
}
