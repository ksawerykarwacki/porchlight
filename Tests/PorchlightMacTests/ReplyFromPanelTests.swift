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
        /// The sessions asked to be woken, and what waking one does. Never the real `claude`.
        let woken = Box<[String]>([])
        var onWake: @MainActor () -> Bool = { false }
        /// Whether `claude agents` lists a process for the session.
        var pid: Int? = 4242

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
            let woken = woken
            inbox.wake = { [unowned self] id in
                woken.value.append(id)
                return await MainActor.run { self.onWake() }
            }
            inbox.wakeWait = (0.6, .milliseconds(20))
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
                    summary: SessionSummary(id: "22222222", sessionId: ReplyFromPanelTests.conversation, name: "asks", cwd: "/Users/u/code/app", kind: "background", state: state, pid: pid),
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
        // It has a process, so waking it was not tried.
        #expect(world.woken.value.isEmpty)
    }

    @Test func aSessionWithoutAProcessIsWokenAndThenRepliedTo() async throws {
        // Finished and gone: `claude agents` lists it without a process, and no mod has spoken.
        let world = try World()
        world.pid = nil
        try world.show(state: .done)
        let row = try #require(world.inbox.rows.first)
        #expect(row.reply == nil && row.canWake)

        // Waking it brings its mod up, which says the session is idle and can take a reply.
        world.listening = false
        world.onWake = { [unowned world] in
            world.report(["kind": "session.start"])
            world.report(["kind": "idle", "id": "s1-9", "can": ["reply"]])
            world.listening = true
            return true
        }
        world.inbox.setReplyDraft(sessionID: "22222222", "Also update the docs.")
        world.inbox.sendReply(sessionID: "22222222")
        #expect(world.inbox.notice == "Waking asks\u{2026}" && world.sent.isEmpty)
        for _ in 0..<300 where world.sent.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(world.woken.value == ["22222222"])
        #expect(world.sent.count == 1 && world.sent[0]["id"] as? String == "s1-9" && world.sent[0]["text"] as? String == "Also update the docs.")
        for _ in 0..<300 where world.inbox.notice != "Woke asks and sent your reply" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(world.inbox.notice == "Woke asks and sent your reply" && world.inbox.replyDrafts.isEmpty)
    }

    @Test func aSessionThatCannotBeWokenOrHasNoModKeepsTheReply() async throws {
        // `claude respawn` failed.
        let failed = try World()
        failed.pid = nil
        try failed.show(state: .unknown("stopped"))
        #expect(failed.inbox.rows.first?.canWake == true)
        failed.inbox.setReplyDraft(sessionID: "22222222", "Carry on.")
        failed.inbox.sendReply(sessionID: "22222222")
        for _ in 0..<300 where failed.copies.value.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where failed.inbox.notice?.hasPrefix("asks could not") != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(failed.inbox.notice == "asks could not be woken. Your reply is on the clipboard: open the session and paste it.")
        #expect(failed.sent.isEmpty && failed.copies.value == ["Carry on."] && failed.inbox.replyDrafts["22222222"] == "Carry on.")

        // It woke, but nothing in it asks for a reply: no companion mod.
        let silent = try World()
        silent.pid = nil
        silent.onWake = { true }
        try silent.show(state: .done)
        silent.inbox.setReplyDraft(sessionID: "22222222", "Carry on.")
        silent.inbox.sendReply(sessionID: "22222222")
        for _ in 0..<400 where silent.copies.value.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        for _ in 0..<300 where silent.inbox.notice?.hasPrefix("asks is awake") != true { try await Task.sleep(for: .milliseconds(10)) }
        #expect(silent.inbox.notice == "asks is awake but is not listening (it may not have the companion mod). Your reply is on the clipboard: open the session and paste it.")
        #expect(silent.sent.isEmpty && silent.inbox.replyDrafts["22222222"] == "Carry on.")

        // A session that is working, or one with a process, is never woken.
        let busy = try World()
        busy.pid = nil
        try busy.show(state: .working)
        #expect(busy.inbox.rows.first?.canWake == false)
        let alive = try World()
        try alive.show(state: .done)
        #expect(alive.inbox.rows.first?.canWake == false)
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
