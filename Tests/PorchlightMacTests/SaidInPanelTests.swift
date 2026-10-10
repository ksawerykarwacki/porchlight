import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

@MainActor
@Suite struct SaidInPanelTests {
    static let conversation = "22222222-0000-4000-8000-000000000000"
    static let said = """
        Layer 3 is now **confirmed** end to end in your installed app: answering works from both the panel and the palette. I've stopped `palette-try` and closed the task.

        Two small things you haven't mentioned either way are the pointer staying an arrow over the panel and the tooltip over an option.

        The next work is layers 4 to 6 (automatic retry, approvals, in-session extras). I'll start when you say which one.
        """

    /// One session that ended its turn with a long reply, reported by the mod.
    func snapshot() throws -> StoreSnapshot {
        let hub = CompanionHub()
        hub.receive(try JSONSerialization.data(withJSONObject: ["v": 1, "session": Self.conversation, "kind": "turn.complete", "reason": "answer", "said": Self.said]))
        let job = try JSONDecoder().decode(JobState.self, from: Data(#"{"state":"blocked","name":"spec.md kickoff","needs":"which one."}"#.utf8))
        var snapshot = StoreSnapshot()
        snapshot.sessions = [
            Session(
                summary: SessionSummary(id: "22222222", sessionId: Self.conversation, name: "spec.md kickoff", cwd: "/Users/u/code/lantern", kind: "background", state: .blocked),
                job: job, companion: hub.snapshot()[Self.conversation])
        ]
        snapshot.fetchedAt = Date()
        return snapshot
    }

    func height(_ actions: InboxActions, named name: String) throws -> CGFloat {
        let view = InboxView(snapshot: try snapshot(), now: Date(), actions: actions, scrolls: false)
        let renderer = ImageRenderer(content: view.background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        if let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return image.size.height
    }

    @Test func theRowShowsTheEndOfTheReplyAndTheRestOnRequest() throws {
        let row = InboxRow(session: try #require(try snapshot().sessions.first), now: Date())
        #expect(row.saidEnding?.hasPrefix("… Two small things") == true && row.said == Self.said)

        var actions = InboxActions()
        var toggled: [String] = []
        actions.toggleSaid = { toggled.append($0) }
        let ending = try height(actions, named: "said-ending")
        actions.expandedSaid = ["22222222"]
        let whole = try height(actions, named: "said-whole")
        #expect(whole > ending + 30)
        actions.toggleSaid("22222222")
        #expect(toggled == ["22222222"])

        // Emphasis and code are drawn as such, not as asterisks and backticks.
        let styled = String(SaidText.styled("It is **done**; see `main`.\nNext line.").characters)
        #expect(styled == "It is done; see main.\nNext line.")
        // Text that is not sound Markdown is still shown.
        #expect(String(SaidText.styled("2 * 3 * 4 and a lone ` tick").characters).contains("lone"))
    }

    @Test func thePaletteShowsOneLineAndOpensTheSelectedRow() async throws {
        let harness = try PaletteHarness()
        let row = InboxRow(session: try #require(try snapshot().sessions.first), now: Date())
        harness.probe.rows = [row]
        await harness.model.begin()
        let model = harness.model
        #expect(PaletteSessionRow(row: row, isSelected: false, hover: HoverTracker()) {}.subtitle == "The next work is layers 4 to 6 (automatic retry, approvals, in-session extras). I'll start when you say which one.")

        func height(named name: String) throws -> Int {
            let view = PaletteView(model: model, hover: HoverTracker(), drawsFields: false)
            let renderer = ImageRenderer(content: view.padding(12).background(Color.white).environment(\.colorScheme, .light))
            renderer.scale = 2
            let image = try #require(renderer.nsImage)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            if let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
                let url = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
            }
            return bitmap.pixelsHigh
        }
        // The session is first in the list and so selected: its row is open. Moved off it, closed.
        #expect(model.selectedSession?.id == "22222222")
        let open = try height(named: "palette-said-selected")
        model.moveSelection(by: 1)
        #expect(model.selectedSession == nil)
        let closed = try height(named: "palette-said-unselected")
        #expect(open > closed + 60)
    }

    @Test func thePaletteWindowTakesTheRoomTheScreenHas() {
        // A 16-inch screen leaves about 940 points under the palette's top edge; a small one less
        // than the card can need, a tall one more than it ever will.
        #expect(PaletteController.windowHeight(below: 940) == 940)
        #expect(PaletteController.windowHeight(below: 480) == 620)
        #expect(PaletteController.windowHeight(below: 1800) == 1100)
    }

    @Test func theModelRemembersWhichRowsAreOpen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-said-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inbox = InboxModel(settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory))
        inbox.toggleSaid(sessionID: "a")
        inbox.toggleSaid(sessionID: "b")
        inbox.toggleSaid(sessionID: "a")
        #expect(inbox.expandedSaid == ["b"])
    }
}
