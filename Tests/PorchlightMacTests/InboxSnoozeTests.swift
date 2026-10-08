import Foundation
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

@MainActor
@Suite struct InboxSnoozeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func model() throws -> (InboxModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-inbox-snooze-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reminders = ReminderState.fileURL(in: directory)
        let fixed = now
        let model = InboxModel(settingsURL: Settings.fileURL(in: directory), remindersURL: reminders, clock: { fixed })
        var snapshot = StoreSnapshot()
        snapshot.fetchedAt = now
        snapshot.sessions = [
            Session(summary: SessionSummary(id: "old", name: "old one", cwd: "/x/a", state: .blocked), observedBlockedSince: now - 3 * 3600),
            Session(summary: SessionSummary(id: "new", name: "new one", cwd: "/x/b", state: .blocked), observedBlockedSince: now - 60),
            Session(summary: SessionSummary(id: "busy", name: "busy", cwd: "/x/c", state: .working)),
        ]
        model.apply(snapshot)
        return (model, reminders)
    }

    @Test func snoozingFromTheInboxIsSavedAndTakesTheSessionOutOfTheStatus() async throws {
        let (model, reminders) = try model()
        #expect(model.status == .overdue(count: 2))

        await model.snooze(sessionID: "old", .hour)
        #expect(model.snoozes["old"] == .until(now + 3600))
        #expect(ReminderState.load(from: reminders).snoozes["old"] == .until(now + 3600))
        // The long-waiting one is gone from the status: one left, and no longer overdue.
        #expect(model.status == .waiting(count: 1))
        #expect(model.notice == "old one is snoozed for an hour")
    }

    @Test func wakingBringsItBack() async throws {
        let (model, reminders) = try model()
        await model.snooze(sessionID: "old", .untilChange)
        #expect(model.snoozes["old"] == .untilChange(waitingSince: now - 3 * 3600))
        #expect(model.status == .waiting(count: 1))

        await model.snooze(sessionID: "old", .wake)
        #expect(model.snoozes.isEmpty)
        #expect(ReminderState.load(from: reminders).snoozes.isEmpty)
        #expect(model.status == .overdue(count: 2))
        #expect(model.notice == "Reminders are back on for old one")
    }

    @Test func tomorrowMeansNineTheNextMorning() async throws {
        let (model, _) = try model()
        await model.snooze(sessionID: "new", .tomorrow)
        guard case .until(let end) = model.snoozes["new"] else {
            Issue.record("expected a timed snooze")
            return
        }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: end)
        #expect(parts.hour == 9 && parts.minute == 0)
        #expect(end > now && end.timeIntervalSince(now) <= 33 * 3600)
    }

    @Test func snoozingAnUnknownSessionDoesNothing() async throws {
        let (model, reminders) = try model()
        await model.snooze(sessionID: "nope", .hour)
        #expect(model.snoozes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: reminders.path))
    }

    @Test func aRowOffersWakingOnlyWhenItIsSnoozed() {
        let session = Session(summary: SessionSummary(id: "a", name: "a", cwd: "/x/a", state: .blocked), observedBlockedSince: now - 60)
        #expect(InboxRow(session: session, now: now).snoozeChoices == [.hour, .tomorrow, .untilChange])
        #expect(InboxRow(session: session, snooze: .until(now + 60), now: now).snoozeChoices.first == .wake)
        #expect(SnoozeChoice.allCases.allSatisfy { !$0.title.isEmpty })
        // Until-change needs to know when the wait began.
        let unknown = Session(summary: SessionSummary(id: "b", name: "b", cwd: "/x/b", state: .blocked))
        #expect(SnoozeChoice.untilChange.snooze(for: unknown, now: now) == nil)
        #expect(SnoozeChoice.wake.snooze(for: session, now: now) == nil)
    }
}
