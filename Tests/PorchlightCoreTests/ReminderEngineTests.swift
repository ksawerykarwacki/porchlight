import Foundation
import Testing

@testable import PorchlightCore

/// Collects what the engine delivers and withdraws.
actor FakeDelivery: ReminderDelivery {
    private(set) var delivered: [Reminder] = []
    private(set) var withdrawn: [String] = []

    func deliver(_ reminder: Reminder) { delivered.append(reminder) }
    func withdraw(reminderIDs: [String]) { withdrawn += reminderIDs }
    var deliveredIDs: [String] { delivered.map(\.id) }
}

@Suite struct ReminderEngineTests {
    func setUp() throws -> (ReminderEngine, FakeDelivery, Clock, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-engine-\(UUID().uuidString)")
        let url = ReminderState.fileURL(in: directory)
        let clock = Clock(noon)
        let delivery = FakeDelivery()
        let planner = ReminderPlanner(settings: ReminderSettings(digestMinute: nil), calendar: utc)
        return (ReminderEngine(planner: planner, delivery: delivery, stateURL: url, now: { clock.now }), delivery, clock, url)
    }

    func snapshot(_ sessions: [Session], fetched: Bool = true) -> StoreSnapshot {
        var snapshot = StoreSnapshot()
        snapshot.sessions = sessions
        snapshot.fetchedAt = fetched ? noon : nil
        return snapshot
    }

    @Test func deliversWhatIsDueOnceAndSavesIt() async throws {
        let (engine, delivery, clock, url) = try setUp()
        let sessions = [waiting("a", since: noon)]

        // Nothing before the store has read anything, and nothing before the first step.
        clock.advance(20 * minute)
        #expect(await engine.process(snapshot(sessions, fetched: false)).isEmpty)
        #expect(await delivery.deliveredIDs.isEmpty)

        #expect(await engine.process(snapshot(sessions)).map(\.id) == ["session-a"])
        #expect(await engine.process(snapshot(sessions)).isEmpty)
        #expect(await delivery.deliveredIDs == ["session-a"])
        #expect(FileManager.default.fileExists(atPath: url.path))

        // A second engine on the same file (a restart) does not repeat it.
        let restarted = ReminderEngine(planner: ReminderPlanner(settings: ReminderSettings(digestMinute: nil), calendar: utc), delivery: delivery, stateURL: url, now: { clock.now })
        #expect(await restarted.process(snapshot(sessions)).isEmpty)
    }

    @Test func withdrawsAReminderWhenTheSessionStopsWaiting() async throws {
        let (engine, delivery, clock, _) = try setUp()
        clock.advance(20 * minute)
        await engine.process(snapshot([waiting("a", since: noon), waiting("b", since: noon)]))
        #expect(await delivery.deliveredIDs.sorted() == ["session-a", "session-b"])

        // "a" was answered; "b" still waits.
        await engine.process(snapshot([waiting("b", since: noon)]))
        #expect(await delivery.withdrawn == ["session-a"])
        await engine.process(snapshot([waiting("b", since: noon)]))
        #expect(await delivery.withdrawn == ["session-a"])
    }

    @Test func aSnoozeFromTheAppSilencesAndWithdraws() async throws {
        let (engine, delivery, clock, _) = try setUp()
        let sessions = [waiting("a", since: noon)]
        clock.advance(20 * minute)
        await engine.process(snapshot(sessions))

        await engine.snooze(sessionID: "a", .until(noon + 3 * hour))
        #expect(await delivery.withdrawn == ["session-a"])
        #expect(await engine.snoozes()["a"] == .until(noon + 3 * hour))

        clock.advance(2 * hour)            // 14:20, the two-hour step falls inside the snooze
        #expect(await engine.process(snapshot(sessions)).isEmpty)
        clock.advance(hour)                // 15:20, the snooze has ended
        #expect(await engine.process(snapshot(sessions)).map(\.id) == ["session-a"])
        #expect(await engine.snoozes().isEmpty)
    }

    @Test func aSnoozeWrittenByTheCommandLineIsHonoured() async throws {
        let (engine, delivery, clock, url) = try setUp()
        let sessions = [waiting("a", since: noon)]
        // What `porchlight snooze a 1h` does: edit the file from another process.
        var state = ReminderState.load(from: url)
        state.snooze("a", .until(noon + hour))
        try state.save(to: url)

        clock.advance(20 * minute)
        #expect(await engine.process(snapshot(sessions)).isEmpty)
        #expect(await delivery.deliveredIDs.isEmpty)

        await engine.clearSnooze(sessionID: "a")
        #expect(await engine.process(snapshot(sessions)).map(\.id) == ["session-a"])
    }

    @Test func marksRemindersThatCanOfferASuggestedReply() async throws {
        let summaries = try AgentsCLISource.decode(Fixtures.text("agents-all.json")).sessions
        let sessions = JobStateSource(jobsDirectory: Fixtures.jobs).enrich(summaries)
        var state = ReminderState()
        let reminders = ReminderPlanner(settings: ReminderSettings(digestMinute: nil), calendar: utc)
            .due(sessions: sessions, state: &state, now: Date(timeIntervalSince1970: 1_791_480_200) + hour)
        #expect(reminders.first { $0.id == "session-11111111" }?.offersReply == true)
        #expect(reminders.first { $0.id == "session-22222222" }?.offersReply == false)
    }

    @Test func theActivityLogKeepsRecentLinesOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-log-\(UUID().uuidString)")
        var log = ActivityLog(directory: directory)
        log.maxLines = 3
        for index in 1...5 { log.record("event \(index)\nsecond line", now: noon + Double(index)) }
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines.first == "2026-10-08T12:00:03Z event 3 second line")
        #expect(lines.last?.hasSuffix("event 5 second line") == true)
    }
}
