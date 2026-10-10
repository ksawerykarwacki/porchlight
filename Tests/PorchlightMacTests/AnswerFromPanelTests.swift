import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightMac
@testable import PorchlightUI

private let conversation = "22222222-0000-4000-8000-000000000000"

@MainActor
@Suite struct AnswerFromPanelTests {
    /// An inbox with one session asking "Apple or pear?" through a mod that takes answers, and
    /// one asking through a mod that does not.
    @MainActor final class World {
        let hub = CompanionHub()
        let inbox: InboxModel
        var sent: [(command: [String: Any], to: String)] = []
        /// What the stand-in for the app's listener says: taken at once, or only queued.
        var taken = true

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-answer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            inbox = InboxModel(settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory), companion: hub)
            inbox.sendToCompanion = { [unowned self] command, to in
                self.sent.append(((try? JSONSerialization.jsonObject(with: command) as? [String: Any]) ?? [:], to))
                return self.taken
            }
            report(["id": "q1-5", "can": ["answer"], "questions": [["question": "Apple or pear?", "options": [["label": "apple (Recommended)"], ["label": "pear"]]]]])
            report(["id": "q1-7", "questions": [["question": "Tea or coffee?", "options": [["label": "tea"], ["label": "coffee"]]]]], session: "33333333-0000-4000-8000-000000000000")
            show()
        }

        func report(_ fields: [String: Any], session: String = conversation) {
            var all: [String: Any] = ["v": 1, "session": session, "kind": "question"]
            fields.forEach { all[$0] = $1 }
            hub.receive(try! JSONSerialization.data(withJSONObject: all))
        }

        /// Hands the inbox the sessions as the store would after the reports so far.
        func show() {
            var snapshot = StoreSnapshot()
            let facts = hub.snapshot()
            snapshot.sessions = [
                Session(summary: SessionSummary(id: "22222222", sessionId: conversation, name: "fruit", cwd: "/Users/u/code/app", kind: "background", state: .blocked), companion: facts[conversation]),
                Session(
                    summary: SessionSummary(id: "33333333", sessionId: "33333333-0000-4000-8000-000000000000", name: "drink", cwd: "/Users/u/code/app", kind: "background", state: .blocked),
                    companion: facts["33333333-0000-4000-8000-000000000000"]),
            ]
            snapshot.fetchedAt = Date()
            inbox.apply(snapshot)
        }
    }

    @Test func oneClickSendsNothingAndSendSendsTheChoice() throws {
        let world = try World()
        let inbox = world.inbox
        #expect(inbox.rows.first { $0.id == "22222222" }?.isAnswerable == true)

        inbox.chooseAnswer(sessionID: "22222222", option: 1)
        #expect(inbox.pendingAnswer == .init(sessionID: "22222222", option: 1, questionID: "q1-5") && world.sent.isEmpty)
        // Another click changes the choice; Cancel drops it; neither sends.
        inbox.chooseAnswer(sessionID: "22222222", option: 0)
        #expect(inbox.pendingAnswer?.option == 0)
        inbox.cancelAnswer()
        inbox.sendAnswer()
        #expect(inbox.pendingAnswer == nil && world.sent.isEmpty)

        inbox.chooseAnswer(sessionID: "22222222", option: 1)
        inbox.sendAnswer()
        #expect(world.sent.count == 1 && world.sent[0].to == conversation)
        #expect(world.sent[0].command["id"] as? String == "q1-5" && world.sent[0].command["answers"] as? [String: String] == ["Apple or pear?": "pear"])
        #expect(inbox.pendingAnswer == nil && inbox.notice == "Answered fruit: pear")
        // Send again with nothing chosen: nothing more goes out.
        inbox.sendAnswer()
        #expect(world.sent.count == 1)

        // The first option is sent as the session wrote it, not as the row shows it.
        inbox.chooseAnswer(sessionID: "22222222", option: 0)
        inbox.sendAnswer()
        #expect(world.sent[1].command["answers"] as? [String: String] == ["Apple or pear?": "apple (Recommended)"])
    }

    @Test func whatCannotBeAnsweredCannotBeChosen() throws {
        let world = try World()
        let inbox = world.inbox
        // A mod that does not take answers, an option that is not there, a session that is not.
        #expect(inbox.rows.first { $0.id == "33333333" }?.isAnswerable == false)
        inbox.chooseAnswer(sessionID: "33333333", option: 0)
        inbox.chooseAnswer(sessionID: "22222222", option: 2)
        inbox.chooseAnswer(sessionID: "gone9999", option: 0)
        #expect(inbox.pendingAnswer == nil)
        inbox.sendAnswer()
        #expect(world.sent.isEmpty)
    }

    @Test func aChoiceDoesNotOutliveItsQuestion() throws {
        let world = try World()
        let inbox = world.inbox
        inbox.chooseAnswer(sessionID: "22222222", option: 1)
        // Answered in the terminal meanwhile: the choice goes with the question.
        world.report(["kind": "resumed"])
        world.show()
        #expect(inbox.pendingAnswer == nil)
        inbox.sendAnswer()
        #expect(world.sent.isEmpty)

        // A new question takes the old one's place while a choice is up: the choice is dropped,
        // and is never sent as an answer to the new one.
        world.report(["id": "q2-9", "can": ["answer"], "questions": [["question": "Apple or pear?", "options": [["label": "apple"], ["label": "pear"]]]]])
        world.show()
        inbox.chooseAnswer(sessionID: "22222222", option: 1)
        world.report(["id": "q3-1", "can": ["answer"], "questions": [["question": "Red or green?", "options": [["label": "red"], ["label": "green"]]]]])
        world.show()
        #expect(inbox.pendingAnswer == nil)
        #expect(inbox.answer(.init(sessionID: "22222222", option: 1, questionID: "q2-9")) == "That question is no longer open; nothing was sent")
        #expect(world.sent.isEmpty)

        // Before the store has read the new question the row still shows the old one; what goes
        // out then carries the old id, which the mod refuses.
        inbox.chooseAnswer(sessionID: "22222222", option: 1)
        world.report(["id": "q4-2", "can": ["answer"], "questions": [["question": "Up or down?", "options": [["label": "up"], ["label": "down"]]]]])
        inbox.sendAnswer()
        #expect(world.sent.count == 1 && world.sent.last?.command["id"] as? String == "q3-1")
    }

    @Test func aCommandThatWasOnlyQueuedIsSaidToBe() throws {
        let world = try World()
        world.taken = false
        world.inbox.chooseAnswer(sessionID: "22222222", option: 1)
        world.inbox.sendAnswer()
        #expect(world.sent.count == 1 && world.inbox.notice == "Sent to fruit. If it does not move on, open it and answer there.")
        // Without a listener at all, as in a build that does not listen: said, and nothing sent.
        world.inbox.sendToCompanion = nil
        world.inbox.chooseAnswer(sessionID: "22222222", option: 1)
        world.inbox.sendAnswer()
        #expect(world.sent.count == 1 && world.inbox.notice == "That question is no longer open; nothing was sent")
    }

    @Test func theRealListenerHandsTheAnswerToTheRequestThatIsWaiting() async throws {
        let rig = try CompanionRig(hold: 20)
        let target = AnswerTarget(sessionID: conversation, questionID: "q1-5", question: "Apple or pear?", options: ["apple", "pear"])
        let command = try #require(target.command(choosing: 1))
        // Nobody asking: queued, and said so.
        #expect(!rig.listener.send(command, to: "44444444-0000-4000-8000-000000000000"))
        async let waiting = rig.request("GET", "/v1/next?session=\(conversation)", timeout: 15)
        // Not before the request has arrived and is held, however slow the machine.
        for _ in 0..<1000 where rig.listener.heldCount(for: conversation) == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.listener.send(command, to: conversation))
        let got = try await waiting
        #expect(got.status == 200)
        let body = try #require(JSONSerialization.jsonObject(with: Data(got.body.utf8)) as? [String: Any])
        #expect(body["id"] as? String == "q1-5" && body["answers"] as? [String: String] == ["Apple or pear?": "pear"])
    }

    @Test func anAnswerNobodyCameForIsNotGivenToALaterAsking() async throws {
        let target = AnswerTarget(sessionID: conversation, questionID: "q1-5", question: "Apple or pear?", options: ["apple", "pear"])
        let command = try #require(target.command(choosing: 1))
        // Queued, and still fresh: the next request takes it, however slow the machine.
        let patient = try CompanionRig(hold: 0.3)
        #expect(!patient.listener.send(command, to: conversation))
        #expect(try await patient.request("GET", "/v1/next?session=\(conversation)", timeout: 15).status == 200)
        // Queued and left past its time: by the time the mod asks, it is gone.
        let rig = try CompanionRig(hold: 0.3, commandLifetime: 0.2)
        #expect(!rig.listener.send(command, to: conversation))
        try await Task.sleep(for: .milliseconds(900))
        #expect(try await rig.request("GET", "/v1/next?session=\(conversation)", timeout: 15).status == 204)
    }

    func height(_ actions: InboxActions, _ snapshot: StoreSnapshot, named name: String? = nil) throws -> CGFloat {
        let view = InboxView(snapshot: snapshot, now: Date(), actions: actions, scrolls: false)
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

    @Test func theRowDrawsTheChoiceAndItsSendButton() throws {
        let world = try World()
        var actions = InboxActions()
        var calls: [String] = []
        actions.chooseAnswer = { calls.append("choose \($0) \($1)") }
        actions.sendAnswer = { calls.append("send") }
        actions.cancelAnswer = { calls.append("cancel") }
        let plain = try height(actions, world.inbox.snapshot, named: "answer-plain")
        actions.pendingAnswer = .init(sessionID: "22222222", option: 1, questionID: "q1-5")
        let chosen = try height(actions, world.inbox.snapshot, named: "answer-chosen")
        // The Send and Cancel line is added under the options.
        #expect(chosen > plain + 20)
        // A choice for a row that is not showing draws nothing.
        actions.pendingAnswer = .init(sessionID: "gone9999", option: 0, questionID: "q1-5")
        #expect(try height(actions, world.inbox.snapshot) == plain)
        // Nor does a choice made for an earlier asking of this row's question.
        actions.pendingAnswer = .init(sessionID: "22222222", option: 1, questionID: "q0-1")
        #expect(try height(actions, world.inbox.snapshot) == plain)

        actions.chooseAnswer("22222222", 1)
        actions.sendAnswer()
        actions.cancelAnswer()
        #expect(calls == ["choose 22222222 1", "send", "cancel"])
        #expect(AnswerBar.sendTitle("pear") == "Send “pear”")
        #expect(AnswerBar.sendTitle(String(repeating: "x", count: 40)).count == "Send “”".count + 28)
    }
}
