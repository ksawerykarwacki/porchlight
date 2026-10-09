import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

@MainActor
@Suite struct TriageWrapUpTests {
    @Test func nothingIsSummarisedUntilTheQuestionIsAnswered() async {
        let world = TriageWorld()
        let model = world.model
        await model.load()
        // Confirming with no question up does nothing.
        await model.confirmWrapUp()
        model.askWrapUp("wait0005")
        #expect(model.pendingWrapUp == "wait0005" && world.wrapped.isEmpty)
        model.cancelWrapUp()
        await model.confirmWrapUp()
        #expect(model.pendingWrapUp == nil && world.wrapped.isEmpty && model.notes.isEmpty)
        // A session that is not in the list cannot be asked about.
        model.askWrapUp("busy0006")
        model.askWrapUp("gone9999")
        #expect(model.pendingWrapUp == nil)
        // The question says what it costs and that the session is left alone.
        let question = TriageRow.wrapUpQuestion(model: "haiku")
        #expect(question.contains("with haiku") && question.contains("every tool off") && question.contains("Claude usage") && question.contains("not changed"))
    }

    @Test func aSummaryIsShownOnTheRowAndKept() async {
        let world = TriageWorld()
        let model = world.model
        await model.load()
        model.askWrapUp("wait0005")
        await model.confirmWrapUp()
        #expect(world.wrapped == ["wait0005 haiku"])
        #expect(model.pendingWrapUp == nil && model.summarising == nil && model.wrapUpProblem == nil)
        #expect(model.notes["wait0005"]?.summary.hasPrefix("Doing: forgotten.") == true)
        #expect(world.archive.note(for: "wait0005") == model.notes["wait0005"])
        // Confirming again without a new question does not summarise again.
        await model.confirmWrapUp()
        #expect(world.wrapped.count == 1)
        // A model made later finds the note on its first look.
        let later = world.model
        #expect(later.notes.isEmpty)
        await later.load()
        #expect(later.notes.keys.sorted() == ["wait0005"])
        #expect(TriageNote.caption(later.notes["wait0005"]!, now: TriageWorld.now + 2 * TriageWorld.day) == "Summarised 2d ago with haiku. Kept after the session is removed.")
        #expect(TriageNote.caption(later.notes["wait0005"]!, now: TriageWorld.now).hasPrefix("Summarised just now with haiku."))
    }

    @Test func aFailureIsShownInItsOwnWordsAndLeavesNoNote() async {
        let world = TriageWorld()
        world.wrapUpFailure = .failed("No conversation found with session ID: 22222222")
        let model = world.model
        await model.load()
        model.askWrapUp("wait0005")
        await model.confirmWrapUp()
        #expect(model.wrapUpProblem == .init(id: "wait0005", text: "No conversation found with session ID: 22222222"))
        #expect(model.notes.isEmpty && world.archive.all().isEmpty && model.summarising == nil)
        // Asking again clears the old problem; dismissing does too.
        model.askWrapUp("wait0005")
        #expect(model.wrapUpProblem == nil)
        world.wrapUpFailure = .notSupported(missing: ["--tools"])
        await model.confirmWrapUp()
        #expect(model.wrapUpProblem?.text == "This version of Claude Code cannot do this safely: it has no --tools.")
        model.dismissWrapUpProblem()
        #expect(model.wrapUpProblem == nil)
    }

    @Test func twoSummariesNeverRunAtOnce() async {
        let world = TriageWorld()
        world.holdsWrapUp = true
        let model = world.model
        await model.load()
        model.askWrapUp("wait0005")
        let running = Task { await model.confirmWrapUp() }
        while model.summarising == nil { await Task.yield() }
        #expect(model.summarising == "wait0005" && model.pendingWrapUp == nil)
        // While it runs, no other question can be put, and confirming again starts nothing.
        model.askWrapUp("safe0002")
        #expect(model.pendingWrapUp == nil)
        await model.confirmWrapUp()
        #expect(world.wrapped == ["wait0005 haiku"])
        world.release()
        await running.value
        #expect(model.summarising == nil && model.notes["wait0005"] != nil)
        model.askWrapUp("safe0002")
        #expect(model.pendingWrapUp == "safe0002")
    }

    @Test func aNoteStaysWhenItsSessionIsRemovedOrKept() async {
        let world = TriageWorld()
        let model = world.model
        await model.load()
        model.askWrapUp("safe0001")
        await model.confirmWrapUp()
        model.askWrapUp("safe0002")
        // Keeping a session takes its question away with its row.
        model.exclude("safe0002")
        #expect(model.pendingWrapUp == nil)
        model.askRemoveSafe()
        await model.confirmRemoveSafe()
        #expect(world.removed == ["safe0001"])
        #expect(!model.items.contains { $0.id == "safe0001" })
        // The session is gone; its note is still on disk and still found by search.
        #expect(world.archive.note(for: "safe0001")?.name == "merged fix")
        #expect(world.archive.search("merged").map(\.id) == ["safe0001"])
        #expect(model.notes["safe0001"] != nil)
    }

    func height(_ actions: InboxActions, named name: String? = nil) throws -> CGFloat {
        let view = InboxView(snapshot: StoreSnapshot(), now: TriageWorld.now, actions: actions, scrolls: false)
        let renderer = ImageRenderer(content: view.background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        if let name, let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return image.size.height
    }

    @Test func theRowDrawsItsQuestionItsProgressItsProblemAndItsNote() async throws {
        let world = TriageWorld()
        let model = world.model
        await model.load()
        var actions = InboxActions()
        actions.showsTriage = true
        actions.triageNow = TriageWorld.now
        actions.triage = TriageState(model)
        let plain = try height(actions)

        model.askWrapUp("wait0005")
        actions.triage = TriageState(model)
        #expect(actions.triage.pendingWrapUp == "wait0005" && actions.triage.wrapUpModel == "haiku")
        #expect(try height(actions, named: "triage-wrap-asking") > plain + 60)

        await model.confirmWrapUp()
        actions.triage = TriageState(model)
        let withNote = try height(actions, named: "triage-wrap-note")
        #expect(withNote > plain + 70)

        var busy = actions
        busy.triage.summarising = "safe0002"
        // The line of progress is drawn, and the note already there stays.
        #expect(try height(busy) > withNote + 10)

        var failed = actions
        failed.triage.wrapUpProblem = .init(id: "safe0002", text: "No conversation found with session ID: 2")
        #expect(try height(failed, named: "triage-wrap-problem") > withNote + 40)

        // With a note on a row the three tabs are still one height in the live panel.
        func live(_ configure: (inout InboxActions) -> Void) -> CGFloat {
            var actions = InboxActions()
            configure(&actions)
            return NSHostingController(rootView: InboxView(snapshot: StoreSnapshot(), now: TriageWorld.now, actions: actions)).sizeThatFits(in: .zero).height
        }
        let state = TriageState(model)
        #expect(live { $0.triage = state } == live { $0.triage = state; $0.showsTriage = true })
    }

    @Test func theRowsButtonsCallTheirActions() {
        var calls: [String] = []
        var actions = InboxActions()
        actions.askWrapUp = { calls.append("ask \($0)") }
        actions.confirmWrapUp = { calls.append("confirm") }
        actions.cancelWrapUp = { calls.append("cancel") }
        actions.dismissWrapUpProblem = { calls.append("dismiss") }
        actions.copyResumeCommand = { calls.append("copy \($0.resumeCommand)") }
        actions.askWrapUp("wait0005")
        actions.cancelWrapUp()
        actions.confirmWrapUp()
        actions.dismissWrapUpProblem()
        actions.copyResumeCommand(SessionNote(
            id: "a", sessionID: "22222222-0000-4000-8000-000000000000", name: "n", repo: "r", directory: "/Users/u/code/app", summary: "s", model: "haiku",
            createdAt: TriageWorld.now))
        #expect(calls == ["ask wait0005", "cancel", "confirm", "dismiss", "copy cd /Users/u/code/app && claude --resume 22222222-0000-4000-8000-000000000000"])
    }
}
