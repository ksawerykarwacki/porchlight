import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

@MainActor
@Suite struct PaletteReplyTests {
    static let conversation = "22222222-0000-4000-8000-000000000000"

    /// One waiting session that finished a turn; its mod takes a reply, or not.
    static func row(takesReply: Bool = true, suggested: String? = "Yes, merge it.", turn: String = "t1-5") throws -> InboxRow {
        let hub = CompanionHub(now: { PaletteHarness.now })
        let report: [String: Any] = [
            "v": 1, "session": conversation, "kind": "turn.complete", "reason": "answer", "said": "The build is green.\n\nShall I merge it, or wait for review?",
            "id": turn, "can": takesReply ? ["reply"] : [],
        ]
        hub.receive(try JSONSerialization.data(withJSONObject: report))
        var json: [String: Any] = ["state": "blocked", "name": "release", "needs": "merge or wait?"]
        if let suggested { json["suggestedReply"] = suggested }
        let job = try JSONDecoder().decode(JobState.self, from: JSONSerialization.data(withJSONObject: json))
        let session = Session(
            summary: SessionSummary(id: "22222222", sessionId: conversation, name: "release", cwd: "/Users/u/code/docs", kind: "background", state: .blocked),
            job: job, companion: hub.snapshot()[conversation])
        return InboxRow(session: session, now: PaletteHarness.now)
    }

    final class Calls: @unchecked Sendable {
        var replies: [(session: String, turn: String, text: String)] = []
        var copied: [String] = []
        var opened: [String] = []
        var outcome: (sent: Bool, message: String) = (true, "Sent your reply to release")
    }

    /// The palette open on that session, selected.
    func harness(_ row: InboxRow) async throws -> (PaletteHarness, Calls) {
        let harness = try PaletteHarness()
        harness.probe.rows = [row]
        let calls = Calls()
        harness.model.onReply = { session, turn, text in
            calls.replies.append((session, turn, text))
            return calls.outcome
        }
        harness.model.onCopyReply = { calls.copied.append($0) }
        harness.model.onOpenSession = { calls.opened.append($0) }
        await harness.model.begin()
        #expect(harness.model.selectedSession?.id == "22222222")
        return (harness, calls)
    }

    @Test func commandReturnOpensAFieldAndCommandReturnAgainSends() async throws {
        let (harness, calls) = try await harness(try Self.row())
        let model = harness.model
        model.replyOrCopySelected()
        #expect(model.step == .reply && model.replyRow?.id == "22222222" && model.replyText.isEmpty)
        // Nothing was copied or opened, and nothing is sent while the field is empty.
        #expect(calls.copied.isEmpty && calls.opened.isEmpty && !model.canSendReply)
        await model.sendReply()
        #expect(calls.replies.isEmpty)

        model.setReplyText("Wait for review.\nThen merge.")
        #expect(model.canSendReply)
        await model.sendReply()
        #expect(calls.replies.count == 1)
        #expect(calls.replies[0].session == "22222222" && calls.replies[0].turn == "t1-5" && calls.replies[0].text == "Wait for review.\nThen merge.")
        // Sent: back on the list, the palette still open, and it says so.
        #expect(model.step == .folder && model.controlMessage == "Sent your reply to release" && model.replyText.isEmpty && model.replyRow == nil)
        #expect(harness.closed.values.isEmpty)
    }

    @Test func aReplyThatDidNotGoIsKeptWithTheReason() async throws {
        let (harness, calls) = try await harness(try Self.row())
        let model = harness.model
        calls.outcome = (false, "release is not listening. Your reply is on the clipboard: open the session and paste it.")
        model.replyOrCopySelected()
        model.setReplyText("Yes.")
        await model.sendReply()
        #expect(model.step == .reply && model.replyText == "Yes." && model.replyMessage?.hasPrefix("release is not listening") == true)
        // Typing again clears the reason; Escape goes back to the list and drops the text.
        model.setReplyText("Yes!")
        #expect(model.replyMessage == nil)
        model.escape()
        #expect(model.step == .folder && model.replyText.isEmpty && harness.closed.values.isEmpty)
        // A second Escape closes the palette, as it always did on the list.
        model.escape()
        #expect(harness.closed.values.count == 1)
    }

    @Test func theSuggestionFillsOnlyAnEmptyField() async throws {
        let (harness, calls) = try await harness(try Self.row())
        let model = harness.model
        model.useSuggestedReply()
        #expect(model.replyText.isEmpty)
        model.replyOrCopySelected()
        model.useSuggestedReply()
        #expect(model.replyText == "Yes, merge it." && calls.replies.isEmpty)
        model.setReplyText("No.")
        model.useSuggestedReply()
        #expect(model.replyText == "No.")
        // Opening the palette again starts clean.
        await model.begin()
        #expect(model.step == .folder && model.replyText.isEmpty && model.replyRow == nil)
    }

    @Test func aSessionThatTakesNoReplyKeepsCopyAndOpen() async throws {
        let (harness, calls) = try await harness(try Self.row(takesReply: false))
        let model = harness.model
        model.replyOrCopySelected()
        #expect(model.step == .folder && calls.copied == ["22222222"] && calls.opened == ["22222222"] && calls.replies.isEmpty)

        // And with neither a reply target nor a suggestion, ⌘Return does nothing.
        let (bare, bareCalls) = try await self.harness(try Self.row(takesReply: false, suggested: nil))
        bare.model.replyOrCopySelected()
        #expect(bare.model.step == .folder && bareCalls.copied.isEmpty && bareCalls.opened.isEmpty)
    }

    func height(_ model: PaletteModel, named name: String) throws -> Int {
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

    @Test func theReplyStepShowsWhatIsRepliedToAndTheField() async throws {
        let (harness, _) = try await harness(try Self.row())
        let model = harness.model
        _ = try height(model, named: "palette-reply-list")
        model.replyOrCopySelected()
        let empty = try height(model, named: "palette-reply-empty")
        model.setReplyText("Wait for review, then merge.")
        // With text the offer of the suggestion goes: the user has written their own.
        let typed = try height(model, named: "palette-reply-typed")
        #expect(empty > typed + 20)
        #expect(typed > 300)
    }
}
