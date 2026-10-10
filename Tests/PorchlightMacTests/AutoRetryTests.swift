import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightMac
@testable import PorchlightUI

@MainActor
@Suite struct AutoRetryTests {
    static let conversation = "22222222-0000-4000-8000-000000000000"
    static let start = Date(timeIntervalSince1970: 1_791_540_000)

    /// An inbox over one session, with a clock the test moves and a stand-in for the listener.
    @MainActor final class World {
        let now = Box<Date>(AutoRetryTests.start)
        let hub: CompanionHub
        let inbox: InboxModel
        let settingsURL: URL
        let launcher = RecordingLauncher()
        let copies = Box<[String]>([])
        var sent: [[String: Any]] = []
        /// What the stand-in for the listener says: taken at once, or only queued.
        var taken = true

        init(autoRetry: AutoRetry?, resend: String = "continue") throws {
            let now = now
            hub = CompanionHub(now: { now.value })
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-autoretry-\(UUID().uuidString)")
            var transient = TransientErrors(resend: resend)
            transient.autoRetry = autoRetry
            let url = PorchlightCore.Settings.fileURL(in: directory)
            try PorchlightCore.Settings(transientErrors: transient).save(to: url)
            settingsURL = url
            inbox = InboxModel(
                launcher: launcher, locator: ClaudeLocator(override: "/custom/claude", isExecutable: { $0 == "/custom/claude" }),
                settingsURL: url, remindersURL: ReminderState.fileURL(in: directory), companion: hub, clock: { now.value })
            let copies = copies
            inbox.copy = { text in
                copies.value.append(text)
                return true
            }
            inbox.sendToCompanion = { [unowned self] command, to in
                #expect(to == AutoRetryTests.conversation)
                self.sent.append((try? JSONSerialization.jsonObject(with: command) as? [String: Any]) ?? [:])
                return self.taken
            }
            inbox.sendToCompanionIfWaiting = { [unowned self] command, to in
                #expect(to == AutoRetryTests.conversation)
                // Only what the mod took has gone anywhere.
                if self.taken { self.sent.append((try? JSONSerialization.jsonObject(with: command) as? [String: Any]) ?? [:]) }
                return self.taken
            }
        }

        func report(_ fields: [String: Any]) {
            var all: [String: Any] = ["v": 1, "session": AutoRetryTests.conversation]
            fields.forEach { all[$0] = $1 }
            hub.receive(try! JSONSerialization.data(withJSONObject: all))
        }

        func fail(_ kind: String = "rate_limit", id: String, retry: Bool = true) {
            report(["kind": "failure", "error": kind, "id": id, "can": retry ? ["retry"] : []])
        }

        /// Moves the clock and hands the inbox the sessions, as each read of them does.
        func tick(_ seconds: TimeInterval = 0, state: SessionState = .blocked) {
            now.value += seconds
            var snapshot = StoreSnapshot()
            snapshot.sessions = [
                Session(
                    summary: SessionSummary(id: "22222222", sessionId: AutoRetryTests.conversation, name: "fails", cwd: "/Users/u/code/app", kind: "background", state: state),
                    companion: hub.snapshot()[AutoRetryTests.conversation])
            ]
            snapshot.fetchedAt = now.value
            inbox.apply(snapshot)
        }
    }

    @Test func nothingIsSentUnlessItIsTurnedOn() throws {
        let world = try World(autoRetry: nil)
        #expect(world.inbox.transientErrors.autoRetry == nil)
        world.fail(id: "f1-1")
        world.tick()
        world.tick(3600)
        world.tick(86_400)
        #expect(world.sent.isEmpty)
        #expect(world.inbox.rows.first?.autoRetry == nil && world.inbox.rows.first?.isRetryable == true)
    }

    @Test func aRetryIsSentOnceWhenItsWaitIsOver() throws {
        let world = try World(autoRetry: AutoRetry(after: 300, attempts: 3), resend: "please continue")
        world.fail(id: "f1-1")
        world.tick()
        world.tick(299)
        #expect(world.sent.isEmpty)
        #expect(world.inbox.rows.first?.autoRetry == .scheduled(at: Self.start + 300, attempt: 1, of: 3))

        world.tick(1)
        #expect(world.sent.count == 1)
        #expect(world.sent[0]["type"] as? String == "retry" && world.sent[0]["id"] as? String == "f1-1" && world.sent[0]["text"] as? String == "please continue")
        // The session is read again many times before it is seen to move on: still once.
        world.tick(10)
        world.tick(600)
        #expect(world.sent.count == 1)
    }

    @Test func eachFailureInARowWaitsLongerAndTheCapEndsIt() throws {
        let world = try World(autoRetry: AutoRetry(after: 60, attempts: 2))
        world.fail(id: "f1-1")
        world.tick(60)
        #expect(world.sent.map { $0["id"] as? String } == ["f1-1"])

        // The retry started a turn, which failed again: twice the wait this time.
        world.report(["kind": "turn.start"])
        world.fail("overloaded", id: "f2-2")
        world.tick()
        world.tick(119)
        #expect(world.sent.count == 1)
        world.tick(1)
        #expect(world.sent.map { $0["id"] as? String } == ["f1-1", "f2-2"])

        // A third failure in a row is past the cap: left to the user, however long it waits.
        world.report(["kind": "turn.start"])
        world.fail(id: "f3-3")
        world.tick()
        world.tick(86_400)
        #expect(world.sent.count == 2)
        #expect(world.inbox.rows.first?.autoRetry == .exhausted(attempts: 2))

        // A turn that answers starts over.
        world.report(["kind": "turn.start"])
        world.report(["kind": "turn.complete", "reason": "answer"])
        world.report(["kind": "turn.start"])
        world.fail(id: "f4-4")
        world.tick(60)
        #expect(world.sent.map { $0["id"] as? String } == ["f1-1", "f2-2", "f4-4"])
    }

    @Test func whatNeedsAPersonOrWasNotReportedIsNeverRetried() throws {
        let world = try World(autoRetry: AutoRetry(after: 60, attempts: 3))
        // A class that does not clear, even from a mod that says it would retry it.
        for (index, kind) in ["authentication_failed", "billing_error", "invalid_request", "model_not_found"].enumerated() {
            world.fail(kind, id: "f\(index)-1")
            world.tick(7200)
        }
        // A mod that takes no retry.
        world.fail(id: "f9-1", retry: false)
        world.tick(7200)
        // A clearing failure the session has since moved on from, and one in a session not waiting.
        world.fail(id: "f10-1")
        world.report(["kind": "turn.start"])
        world.tick(7200)
        world.fail(id: "f11-1")
        world.tick(7200, state: .working)
        #expect(world.sent.isEmpty)

        // A session the mod never reported, though what Claude Code says of it reads like a failure.
        let plain = try World(autoRetry: AutoRetry(after: 60, attempts: 3))
        let job = try JSONDecoder().decode(JobState.self, from: Data(#"{"state":"blocked","name":"n","needs":"API Error: Rate limit reached"}"#.utf8))
        var snapshot = StoreSnapshot()
        snapshot.sessions = [Session(summary: SessionSummary(id: "33333333", sessionId: "33333333-0000-4000-8000-000000000000", name: "n", state: .blocked), job: job)]
        plain.now.value += 7200
        plain.inbox.apply(snapshot)
        #expect(plain.inbox.rows.first?.isRetryable == true && plain.sent.isEmpty)
    }

    @Test func aRetryNobodyTookIsSentAgainOnlyAfterTheQueueDroppedIt() throws {
        let world = try World(autoRetry: AutoRetry(after: 60, attempts: 3))
        world.taken = false
        world.fail(id: "f1-1")
        world.tick(60)
        world.tick(30)
        world.tick(30)
        #expect(world.sent.count == 1)
        world.tick(31)
        #expect(world.sent.count == 2)
        world.taken = true
        world.tick(91)
        world.tick(600)
        #expect(world.sent.count == 3)
    }

    @Test func theUserCanStopOneRetryAndTurnItAllOff() throws {
        let world = try World(autoRetry: AutoRetry(after: 300, attempts: 3))
        world.fail(id: "f1-1")
        world.tick()
        world.inbox.cancelRetry(sessionID: "22222222")
        #expect(world.inbox.cancelledRetries == ["f1-1"])
        world.tick(3600)
        #expect(world.sent.isEmpty)
        // The next failure is a new one: it is retried.
        world.report(["kind": "turn.start"])
        world.report(["kind": "turn.complete", "reason": "answer"])
        world.report(["kind": "turn.start"])
        world.fail(id: "f2-2")
        world.tick()
        #expect(world.inbox.cancelledRetries.isEmpty)

        // Turned off in Settings, and saved: nothing more, and the row says nothing of a retry.
        world.inbox.setAutoRetry(after: nil)
        world.tick(3600)
        #expect(world.sent.isEmpty && world.inbox.rows.first?.autoRetry == nil)
        #expect(PorchlightCore.Settings.load(from: world.settingsURL).transientErrors?.autoRetry == nil)
        // Turned on again: what is already overdue goes at once, with the user's line kept.
        world.inbox.setAutoRetry(after: 900)
        #expect(PorchlightCore.Settings.load(from: world.settingsURL).transientErrors?.autoRetry == AutoRetry(after: 900, attempts: 3))
        #expect(world.sent.map { $0["id"] as? String } == ["f2-2"])
    }

    @Test func retrySendsThroughTheModWhenItCanAndOpensTheSessionWhenItCannot() async throws {
        let world = try World(autoRetry: nil)
        world.fail("server_error", id: "f1-1")
        world.tick()
        world.inbox.retry(sessionID: "22222222")
        #expect(world.sent.count == 1 && world.sent[0]["text"] as? String == "continue")
        #expect(world.inbox.notice == "Sent \u{201C}continue\u{201D} to fails")
        #expect(await world.launcher.opened.isEmpty && world.copies.value.isEmpty)

        // The mod is not there to take it: as before, the session opened and the line copied,
        // and nothing left behind for the mod to submit as well.
        world.taken = false
        world.inbox.retry(sessionID: "22222222")
        #expect(world.sent.count == 1)
        for _ in 0..<200 where world.copies.value.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(world.copies.value == ["continue"])
        #expect(await world.launcher.opened.map(\.arguments) == [["/custom/claude", "attach", "22222222"]])
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

    @Test func theRowSaysWhatWillBeDoneAndOffersToStopIt() throws {
        let world = try World(autoRetry: AutoRetry(after: 300, attempts: 3))
        world.fail(id: "f1-1")
        world.tick(30)
        let row = try #require(world.inbox.rows.first)
        #expect(RetryNote.isScheduled(row, cancelled: []) && !RetryNote.isScheduled(row, cancelled: ["f1-1"]))
        #expect(RetryNote.text(for: row, cancelled: []) == "Stopped on a rate limit. Trying again in 5 min, attempt 1 of 3.")
        #expect(RetryNote.text(for: row, cancelled: ["f1-1"]) == "Stopped on a rate limit. Not retried by itself, as you asked.")
        _ = try height(row, InboxActions(), named: "retry-scheduled")

        // Past the cap, and with automatic retry off.
        let spent = RetryTarget(sessionID: Self.conversation, failureID: "f4-1", failureClass: "overloaded", failedAt: Self.start, failuresInARow: 4)
        #expect(AutoRetry(after: 300, attempts: 3).standing(for: spent) == .exhausted(attempts: 3))
        let off = try World(autoRetry: nil)
        off.fail("server_error", id: "f1-1")
        off.tick()
        let plain = try #require(off.inbox.rows.first)
        #expect(RetryNote.text(for: plain, cancelled: []) == "Stopped on a server error. Can be retried.")
        #expect(!RetryNote.isScheduled(plain, cancelled: []))
        // Without the mod's report, the old words.
        let job = try JSONDecoder().decode(JobState.self, from: Data(#"{"state":"blocked","name":"n","needs":"API Error: Rate limit reached"}"#.utf8))
        let old = InboxRow(session: Session(summary: SessionSummary(id: "a", name: "n", state: .blocked), job: job), now: Self.start)
        #expect(RetryNote.text(for: old, cancelled: []) == "Can be retried")

        // Settings: off unless set, and a wait written by hand shows as the nearest one offered.
        #expect(SettingsPage.autoRetryChoice(nil) == 0 && SettingsPage.autoRetryChoice(AutoRetry(after: 300)) == 300)
        #expect(SettingsPage.autoRetryChoice(AutoRetry(after: 700)) == 900)
        #expect(SettingsPage.autoRetryLabel(0) == "Off" && SettingsPage.autoRetryLabel(900) == "After 15 min")
        #expect(SettingsPage.autoRetryNote(resend: "continue", attempts: 3).contains("uses your Claude usage"))
    }
}
