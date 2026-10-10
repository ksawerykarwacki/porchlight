import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

@MainActor
@Suite struct PaletteAnswerTests {
    static let fruit = "22222222-0000-4000-8000-000000000000"
    static let drink = "33333333-0000-4000-8000-000000000000"

    /// Two waiting sessions: "fruit" asks through a mod that takes answers, "drink" through one
    /// that does not.
    static func rows(fruitID: String = "q1-5", fruitQuestion: String = "Apple or pear?", fruitOptions: [String] = ["apple (Recommended)", "pear"]) -> [InboxRow] {
        let hub = CompanionHub(now: { PaletteHarness.now })
        func report(_ session: String, _ fields: [String: Any]) {
            var all: [String: Any] = ["v": 1, "session": session, "kind": "question"]
            fields.forEach { all[$0] = $1 }
            hub.receive(try! JSONSerialization.data(withJSONObject: all))
        }
        report(fruit, ["id": fruitID, "can": ["answer"], "questions": [["question": fruitQuestion, "options": fruitOptions.map { ["label": $0] }]]])
        report(drink, ["id": "q1-7", "questions": [["question": "Tea or coffee?", "options": [["label": "tea"], ["label": "coffee"]]]]])
        let facts = hub.snapshot()
        return [
            Session(summary: SessionSummary(id: "22222222", sessionId: fruit, name: "fruit", cwd: "/Users/u/code/docs", kind: "background", state: .blocked), companion: facts[fruit]),
            Session(summary: SessionSummary(id: "33333333", sessionId: drink, name: "drink", cwd: "/Users/u/code/docs", kind: "background", state: .blocked), companion: facts[drink]),
        ].map { InboxRow(session: $0, now: PaletteHarness.now) }
    }

    final class Calls: @unchecked Sendable {
        var answers: [InboxModel.PendingAnswer] = []
        var opened: [String] = []
        var says = "Answered fruit: pear"
    }

    /// The palette open on those two sessions, with "fruit" selected.
    func harness() async throws -> (PaletteHarness, Calls) {
        let harness = try PaletteHarness()
        harness.probe.rows = Self.rows()
        let calls = Calls()
        harness.model.onAnswer = {
            calls.answers.append($0)
            return calls.says
        }
        harness.model.onOpenSession = { calls.opened.append($0) }
        await harness.model.begin()
        let model = harness.model
        if let position = model.items.firstIndex(where: { $0.id == "session:22222222" }) { model.moveSelection(by: position - model.selection) }
        #expect(model.selectedSession?.id == "22222222")
        return (harness, calls)
    }

    /// Lets the task that Return started finish.
    func settle(_ model: PaletteModel, until done: @MainActor () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aNumberChoosesAndReturnSends() async throws {
        let (harness, calls) = try await harness()
        let model = harness.model
        let row = try #require(model.selectedSession)
        #expect(model.canAnswer(row) && model.chosenOption(for: row) == nil)

        model.chooseAnswer(1)
        #expect(model.chosenOption(for: row) == 1 && calls.answers.isEmpty)
        // Another number changes the choice; Escape drops it and leaves the palette open.
        model.chooseAnswer(0)
        #expect(model.pendingAnswer?.option == 0)
        model.escape()
        #expect(model.pendingAnswer == nil && harness.closed.values.isEmpty && calls.answers.isEmpty)

        model.chooseAnswer(1)
        model.confirmFolder()
        await settle(model) { !calls.answers.isEmpty }
        #expect(calls.answers == [.init(sessionID: "22222222", option: 1, questionID: "q1-5")])
        // Return sent the answer; it did not open the session or close the palette.
        #expect(calls.opened.isEmpty && harness.closed.values.isEmpty)
        #expect(model.controlMessage == "Answered fruit: pear" && model.pendingAnswer == nil)

        // The list still holds the question until the session is seen to move on: its options
        // are not offered again for the same asking, and Return opens as it always did.
        let after = try #require(model.selectedSession)
        #expect(after.id == "22222222" && !model.canAnswer(after))
        model.chooseAnswer(0)
        #expect(model.pendingAnswer == nil)
        model.confirmFolder()
        #expect(calls.answers.count == 1 && calls.opened == ["22222222"])
    }

    @Test func aChoiceIsDroppedByAnythingThatMovesOn() async throws {
        let (harness, calls) = try await harness()
        let model = harness.model
        model.chooseAnswer(1)
        model.moveSelection(by: 1)
        #expect(model.pendingAnswer == nil)

        if let position = model.items.firstIndex(where: { $0.id == "session:22222222" }) { model.moveSelection(by: position - model.selection) }
        model.chooseAnswer(1)
        model.setQuery("fru")
        #expect(model.pendingAnswer == nil)

        model.setQuery("")
        if let position = model.items.firstIndex(where: { $0.id == "session:22222222" }) { model.moveSelection(by: position - model.selection) }
        model.chooseAnswer(1)
        #expect(model.pendingAnswer != nil)
        let other = try #require(model.items.first { $0.id != "session:22222222" })
        model.select(other)
        #expect(model.pendingAnswer == nil)

        // Clicking the row it is about keeps it; asking to stop the session replaces it.
        model.setQuery("fruit")
        model.chooseAnswer(1)
        model.select(try #require(model.selectedItem))
        #expect(model.pendingAnswer?.option == 1)
        model.askControlSelected(.stop)
        #expect(model.pendingAnswer == nil && model.pendingControl != nil)
        // And choosing an answer takes the place of that question.
        model.chooseAnswer(0)
        #expect(model.pendingControl == nil && model.pendingAnswer?.option == 0)
        model.toggleNotes()
        #expect(model.pendingAnswer == nil)
        #expect(calls.answers.isEmpty)
    }

    @Test func whatCannotBeAnsweredIsNotChosen() async throws {
        let (harness, calls) = try await harness()
        let model = harness.model
        // No such option.
        model.chooseAnswer(2)
        model.chooseAnswer(-1)
        #expect(model.pendingAnswer == nil)
        // A session whose mod takes no answers, and a folder.
        model.setQuery("drink")
        let drink = try #require(model.selectedSession)
        #expect(drink.id == "33333333" && !model.canAnswer(drink))
        model.chooseAnswer(0)
        model.setQuery("payments")
        #expect(model.selectedSession == nil)
        model.chooseAnswer(0)
        #expect(model.pendingAnswer == nil)
        await model.sendAnswer()
        #expect(calls.answers.isEmpty)
    }

    @Test func aNewAskingOfTheSameSessionIsOfferedAgain() async throws {
        let (harness, calls) = try await harness()
        let model = harness.model
        model.chooseAnswer(1)
        // The session asks something else before Return: what goes out names the asking the
        // choice was made for, which the inbox then refuses.
        harness.probe.rows = Self.rows(fruitID: "q2-9", fruitQuestion: "Red or green?", fruitOptions: ["red", "green"])
        calls.says = "That question is no longer open; nothing was sent"
        await model.sendAnswer()
        #expect(calls.answers.map(\.questionID) == ["q1-5"] && model.controlMessage == "That question is no longer open; nothing was sent")
        // The new question has its own id, so it can be answered.
        let row = try #require(model.selectedSession)
        #expect(row.answerID == "q2-9" && model.canAnswer(row) && model.chosenOption(for: row) == nil)
        model.chooseAnswer(0)
        #expect(model.pendingAnswer == .init(sessionID: "22222222", option: 0, questionID: "q2-9"))
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

    @Test func theOptionsAreDrawnOnlyForASelectedSessionThatCanBeAnswered() async throws {
        let (harness, _) = try await harness()
        let model = harness.model
        let answerable = try height(model, named: "palette-answer")
        model.chooseAnswer(1)
        let chosen = try height(model, named: "palette-answer-chosen")
        // Choosing changes the footer, not the height.
        #expect(abs(chosen - answerable) <= 2)

        // The same list with the other session selected: its row stays closed.
        if let position = model.items.firstIndex(where: { $0.id == "session:33333333" }) { model.moveSelection(by: position - model.selection) }
        #expect(model.selectedSession?.id == "33333333")
        let plain = try height(model, named: "palette-answer-none")
        #expect(answerable > plain + 40)
    }
}
