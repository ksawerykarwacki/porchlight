import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

@MainActor
@Suite struct ReplyFromPanelTests {
    static let conversation = "22222222-0000-4000-8000-000000000000"

    /// An inbox over one session that finished a turn and waits, with a stand-in for the listener.
    @MainActor final class World {
        let hub = CompanionHub()
        let inbox: InboxModel
        let copies = Box<[String]>([])
        var sent: [[String: Any]] = []
        /// Whether the session's mod is waiting for a command right now.
        var listening = true

        init() throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-reply-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            inbox = InboxModel(settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory), companion: hub)
            let copies = copies
            inbox.copy = { text in
                copies.value.append(text)
                return true
            }
            inbox.sendToCompanionIfWaiting = { [unowned self] command, to in
                #expect(to == ReplyFromPanelTests.conversation)
                if self.listening { self.sent.append((try? JSONSerialization.jsonObject(with: command) as? [String: Any]) ?? [:]) }
                return self.listening
            }
            // Never the one that queues: a reply must not arrive later, when nobody expects it.
            inbox.sendToCompanion = { _, _ in
                Issue.record("a reply was queued")
                return false
            }
        }

        func report(_ fields: [String: Any]) {
            var all: [String: Any] = ["v": 1, "session": ReplyFromPanelTests.conversation]
            fields.forEach { all[$0] = $1 }
            hub.receive(try! JSONSerialization.data(withJSONObject: all))
        }

        func finishTurn(id: String, reply: Bool = true) {
            report(["kind": "turn.complete", "reason": "answer", "said": "All done.\n\nShall I merge?", "id": id, "can": reply ? ["reply"] : []])
        }

        /// Hands the inbox the session, as each read of the sessions does.
        func show(state: SessionState = .blocked, suggested: String? = nil) throws {
            var json: [String: Any] = ["state": "blocked", "name": "asks", "needs": "merge?"]
            if let suggested { json["suggestedReply"] = suggested }
            let job = try JSONDecoder().decode(JobState.self, from: JSONSerialization.data(withJSONObject: json))
            var snapshot = StoreSnapshot()
            snapshot.sessions = [
                Session(
                    summary: SessionSummary(id: "22222222", sessionId: ReplyFromPanelTests.conversation, name: "asks", cwd: "/Users/u/code/app", kind: "background", state: state),
                    job: job, companion: hub.snapshot()[ReplyFromPanelTests.conversation])
            ]
            snapshot.fetchedAt = Date()
            inbox.apply(snapshot)
        }
    }

    @Test func whatIsTypedIsSentOnlyWhenTheUserSendsIt() throws {
        let world = try World()
        world.finishTurn(id: "t1-5")
        try world.show()
        let inbox = world.inbox
        #expect(inbox.rows.first?.reply == ReplyTarget(sessionID: Self.conversation, turnID: "t1-5"))

        // Typing sends nothing; nor does sending nothing.
        inbox.sendReply(sessionID: "22222222")
        inbox.setReplyDraft(sessionID: "22222222", "Yes")
        inbox.setReplyDraft(sessionID: "22222222", "  Yes, merge it.\nThen update the docs. ")
        #expect(world.sent.isEmpty && inbox.replyDrafts["22222222"]?.hasPrefix("  Yes") == true)

        inbox.sendReply(sessionID: "22222222")
        #expect(world.sent.count == 1)
        #expect(world.sent[0]["type"] as? String == "reply" && world.sent[0]["id"] as? String == "t1-5")
        #expect(world.sent[0]["text"] as? String == "Yes, merge it.\nThen update the docs.")
        // Sent: the field is empty again, and it is said.
        #expect(inbox.replyDrafts.isEmpty && inbox.notice == "Sent your reply to asks")
        inbox.sendReply(sessionID: "22222222")
        #expect(world.sent.count == 1)
    }

    @Test func aReplyGoesOnlyToTheTurnItWasWrittenFor() throws {
        let world = try World()
        world.finishTurn(id: "t1-5")
        try world.show()
        let inbox = world.inbox
        inbox.setReplyDraft(sessionID: "22222222", "Yes, merge it.")
        // The session went on by itself and finished another turn: the draft was for the last one.
        world.report(["kind": "turn.start"])
        world.finishTurn(id: "t2-9")
        try world.show()
        #expect(inbox.replyDrafts.isEmpty)
        inbox.sendReply(sessionID: "22222222")
        #expect(world.sent.isEmpty)

        // Before the sessions are read again the row still shows the old turn: what is sent names
        // it, and the mod refuses a reply to a turn that is not its last.
        inbox.setReplyDraft(sessionID: "22222222", "And the docs?")
        world.report(["kind": "turn.start"])
        world.finishTurn(id: "t3-1")
        inbox.sendReply(sessionID: "22222222")
        #expect(world.sent.map { $0["id"] as? String } == ["t2-9"])
    }

    @Test func nothingCanBeSentWhereNoReplyIsTaken() throws {
        // A turn is running, the session is not waiting, it waits on a question, an approval or a
        // failure, or its mod takes no reply: no target, and typing is not even kept.
        for change in [
            { (w: World) in w.report(["kind": "turn.start"]) },
            { (w: World) in w.report(["kind": "permission", "tool": "Bash", "detail": "make"]) },
            { (w: World) in w.report(["kind": "question", "id": "q1-1", "can": ["answer"], "questions": [["question": "A or B?", "options": [["label": "A"], ["label": "B"]]]]]) },
            { (w: World) in w.report(["kind": "failure", "error": "rate_limit", "id": "f1-1", "can": ["retry"]]) },
        ] as [(World) -> Void] {
            let world = try World()
            world.finishTurn(id: "t1-5")
            change(world)
            try world.show()
            #expect(world.inbox.rows.first?.reply == nil)
            world.inbox.setReplyDraft(sessionID: "22222222", "Yes")
            world.inbox.sendReply(sessionID: "22222222")
            #expect(world.inbox.replyDrafts.isEmpty && world.sent.isEmpty)
        }
        let older = try World()
        older.finishTurn(id: "t1-5", reply: false)
        try older.show()
        #expect(older.inbox.rows.first?.reply == nil)
        let working = try World()
        working.finishTurn(id: "t1-5")
        try working.show(state: .working)
        #expect(working.inbox.rows.first?.reply == nil)

        // Too long for the mod to take: said, not sent, and the text is kept.
        let world = try World()
        world.finishTurn(id: "t1-5")
        try world.show()
        world.inbox.setReplyDraft(sessionID: "22222222", String(repeating: "x", count: 4001))
        world.inbox.sendReply(sessionID: "22222222")
        #expect(world.sent.isEmpty && world.inbox.replyDrafts["22222222"]?.count == 4001)
        #expect(world.inbox.notice == "That reply is too long to send from here; open the session and paste it")
    }

    @Test func aSessionThatIsNotListeningGetsNothingAndTheReplyIsKept() async throws {
        let world = try World()
        world.finishTurn(id: "t1-5")
        try world.show()
        world.listening = false
        world.inbox.setReplyDraft(sessionID: "22222222", "Yes, merge it.")
        world.inbox.sendReply(sessionID: "22222222")
        for _ in 0..<200 where world.copies.value.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(world.sent.isEmpty && world.copies.value == ["Yes, merge it."])
        #expect(world.inbox.replyDrafts["22222222"] == "Yes, merge it.")
        for _ in 0..<200 where world.inbox.notice == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(world.inbox.notice == "asks is not listening. Your reply is on the clipboard: open the session and paste it.")
        // The panel closing does not lose a half-written reply.
        world.inbox.panelClosed()
        #expect(world.inbox.replyDrafts["22222222"] == "Yes, merge it.")
    }

    @Test func theSuggestedReplyGoesIntoTheFieldNotToTheSession() throws {
        let world = try World()
        world.finishTurn(id: "t1-5")
        try world.show(suggested: "Yes, merge it.")
        world.inbox.useSuggestedReply(sessionID: "22222222")
        #expect(world.inbox.replyDrafts["22222222"] == "Yes, merge it." && world.sent.isEmpty)
        // What the user typed is never replaced by it.
        world.inbox.setReplyDraft(sessionID: "22222222", "No, wait for review.")
        world.inbox.useSuggestedReply(sessionID: "22222222")
        #expect(world.inbox.replyDrafts["22222222"] == "No, wait for review.")
        #expect(world.inbox.notice == "The reply field already has text; clear it to use the suggestion")
        world.inbox.setReplyDraft(sessionID: "22222222", "")
        world.inbox.useSuggestedReply(sessionID: "22222222")
        world.inbox.sendReply(sessionID: "22222222")
        #expect(world.sent.map { $0["text"] as? String } == ["Yes, merge it."])
    }

    @Test func aSessionClaudeCodeCallsDoneCanBeRepliedToOnceItsRowIsOpened() throws {
        // Claude Code decides between "blocked" and "done" from the session's last words, and
        // calls one done that ended by asking what to do next.
        let world = try World()
        world.finishTurn(id: "t1-5")
        try world.show(state: .done)
        let row = try #require(world.inbox.rows.first)
        #expect(row.kind == .done && row.reply == ReplyTarget(sessionID: Self.conversation, turnID: "t1-5"))
        #expect(row.said == "All done.\n\nShall I merge?" && row.saidLine == "Shall I merge?")

        // Folded, the row is small: one line, no field. Opened, it has both.
        var actions = InboxActions()
        let folded = try height(row, actions, named: "done-folded")
        actions.expandedSaid = ["22222222"]
        let opened = try height(row, actions, named: "done-opened")
        #expect(opened > folded + 40)

        world.inbox.setReplyDraft(sessionID: "22222222", "Yes, merge it.")
        world.inbox.sendReply(sessionID: "22222222")
        #expect(world.sent.map { $0["id"] as? String } == ["t1-5"] && world.inbox.notice == "Sent your reply to asks")
        // A finished session without the mod's report is as it was: a name and a place.
        let bare = InboxRow(session: Session(summary: SessionSummary(id: "a", name: "n", state: .done)), now: Date())
        #expect(bare.said == nil && bare.reply == nil)
    }

    func height(_ row: InboxRow, _ actions: InboxActions, named name: String) throws -> CGFloat {
        let renderer = ImageRenderer(
            content: InboxRowView(row: row, actions: actions, hover: HoverTracker(), drawsMenus: false).frame(width: 400).background(Color.white).environment(\.colorScheme, .light))
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

    @Test func theRowHasAFieldOnlyWhereAReplyCanGo() throws {
        let world = try World()
        world.finishTurn(id: "t1-5")
        try world.show(suggested: "Yes, merge it.")
        let row = try #require(world.inbox.rows.first)
        var actions = InboxActions()
        var calls: [String] = []
        actions.setReplyDraft = { calls.append("draft \($0) \($1)") }
        actions.sendReply = { calls.append("send \($0)") }
        actions.useSuggestedReply = { calls.append("use \($0)") }
        let empty = try height(row, actions, named: "reply-empty")
        actions.replyDrafts = ["22222222": "Yes, merge it."]
        let typed = try height(row, actions, named: "reply-typed")
        #expect(abs(typed - empty) <= 2)

        // The same session with a mod that takes no reply: no field.
        let older = try World()
        older.finishTurn(id: "t1-5", reply: false)
        try older.show(suggested: "Yes, merge it.")
        let plain = try height(try #require(older.inbox.rows.first), InboxActions(), named: "reply-none")
        #expect(empty > plain + 20)

        actions.setReplyDraft("22222222", "Yes")
        actions.useSuggestedReply("22222222")
        actions.sendReply("22222222")
        #expect(calls == ["draft 22222222 Yes", "use 22222222", "send 22222222"])
    }
}
