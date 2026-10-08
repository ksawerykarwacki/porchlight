import Foundation
import Testing

@testable import PorchlightCore

/// A fixed calendar so times of day mean the same thing on every machine.
let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2026-10-08 12:00:00 UTC, a Thursday.
let noon = Date(timeIntervalSince1970: 1_791_460_800)

func waiting(_ id: String, since: Date, name: String? = nil, waitingFor: String? = nil) -> Session {
    Session(
        summary: SessionSummary(id: id, name: name ?? "session \(id)", cwd: "/Users/u/code/repo-\(id)", state: .blocked, waitingFor: waitingFor),
        observedBlockedSince: since)
}

/// Runs the planner at a series of offsets from noon and returns what it sent at each.
func timeline(_ planner: ReminderPlanner, sessions: @escaping (Date) -> [Session], at offsets: [TimeInterval], state: inout ReminderState) -> [[String]] {
    offsets.map { offset in
        let now = noon + offset
        return planner.due(sessions: sessions(now), state: &state, now: now).map { "\($0.id)\($0.withSound ? "+sound" : "")" }
    }
}

let minute: TimeInterval = 60
let hour: TimeInterval = 3600

@Suite struct ReminderLadderTests {
    let planner = ReminderPlanner(settings: ReminderSettings(digestMinute: nil), calendar: utc)

    @Test func remindsOncePerStepThenAtTheRepeatInterval() {
        var state = ReminderState()
        let session = waiting("a", since: noon)
        let sent = timeline(planner, sessions: { _ in [session] }, at: [
            0, 14 * minute,          // before the first step
            15 * minute, 16 * minute, // first step, then nothing more for it
            119 * minute,
            2 * hour, 2 * hour + 10,  // second step, with sound
            5 * hour,                 // not yet 4h after the last step
            6 * hour, 6 * hour + 5,   // first repeat
            10 * hour,                // second repeat
        ], state: &state)
        #expect(sent == [[], [], ["session-a"], [], [], ["session-a+sound"], [], [], ["session-a+sound"], [], ["session-a+sound"]])
    }

    @Test func sendsOneReminderAfterALongAbsenceNotOnePerMissedStep() {
        var state = ReminderState()
        let session = waiting("a", since: noon - 21 * 24 * hour)
        // Waiting since exactly three weeks ago, repeats fall at 02:00, 06:00, 10:00, 14:00, ...
        let sent = timeline(planner, sessions: { _ in [session] }, at: [0, 10, 60, 2 * hour - 1, 2 * hour, 2 * hour + 60, 5 * hour], state: &state)
        // Three weeks of missed steps collapse into one; the next comes with the next repeat.
        #expect(sent == [["session-a+sound"], [], [], [], ["session-a+sound"], [], []])
    }

    @Test func startsAgainWhenTheSessionWaitsOnSomethingNew() {
        var state = ReminderState()
        let sent = timeline(planner, sessions: { now in
            // Answered at 30 min; blocked again on a new question from 40 min.
            now < noon + 30 * minute ? [waiting("a", since: noon)] : (now < noon + 40 * minute ? [] : [waiting("a", since: noon + 40 * minute)])
        }, at: [15 * minute, 35 * minute, 45 * minute, 55 * minute, 56 * minute], state: &state)
        #expect(sent == [["session-a"], [], [], ["session-a"], []])
    }

    @Test func remindsEachSessionOnItsOwnClock() {
        var state = ReminderState()
        let sessions = [waiting("a", since: noon), waiting("b", since: noon + 10 * minute)]
        let sent = timeline(planner, sessions: { _ in sessions }, at: [15 * minute, 25 * minute, 26 * minute], state: &state)
        #expect(sent == [["session-a"], ["session-b"], []])
    }

    @Test func countsStepsForCustomLadders() {
        let settings = ReminderSettings(ladder: [0, 600], repeatEvery: nil)
        #expect(settings.stepsDue(afterWaiting: -5) == 0)
        #expect(settings.stepsDue(afterWaiting: 0) == 1)
        #expect(settings.stepsDue(afterWaiting: 600) == 2)
        #expect(settings.stepsDue(afterWaiting: 1_000_000) == 2)
        let repeating = ReminderSettings(ladder: [], repeatEvery: 3600)
        #expect(repeating.stepsDue(afterWaiting: 3599) == 0)
        #expect(repeating.stepsDue(afterWaiting: 7200) == 2)
        // Unsorted and negative entries are normalised rather than trusted.
        #expect(ReminderSettings(ladder: [7200, -1, 900]).ladder == [900, 7200])
    }

    @Test func saysWhatTheSessionIsWaitingOnUnlessDetailsAreHidden() throws {
        let summaries = try AgentsCLISource.decode(Fixtures.text("agents-all.json")).sessions
        let sessions = JobStateSource(jobsDirectory: Fixtures.jobs).enrich(summaries)
        let now = Date(timeIntervalSince1970: 1_791_480_200) + 20 * minute
        var state = ReminderState()
        let reminders = planner.due(sessions: sessions, state: &state, now: now)
        let question = try #require(reminders.first { $0.id == "session-22222222" })
        #expect(question.title == "rename the file")
        #expect(question.subtitle == "beta")
        #expect(question.body == "Should hello.txt be renamed to greeting.txt or salute.txt?")
        let approval = try #require(reminders.first { $0.id == "session-55555555" })
        #expect(approval.body.hasPrefix("Approve Bash: echo hi > hello.txt"))
        #expect(approval.title == "probe-worktree")
        #expect(approval.subtitle == "probe / add-hello")

        var hidden = planner
        hidden.settings.hideDetails = true
        var fresh = ReminderState()
        let quiet = hidden.due(sessions: sessions, state: &fresh, now: now)
        #expect(quiet.first { $0.id == "session-22222222" }?.body == "Waiting for 21m for your input")
        #expect(quiet.first { $0.id == "session-55555555" }?.body == "Waiting for 22m for your approval")
        #expect(!quiet.contains { $0.body.contains("hello.txt") })
    }
}

@Suite struct ReminderSnoozeTests {
    let planner = ReminderPlanner(settings: ReminderSettings(digestMinute: nil), calendar: utc)

    @Test func staysSilentUntilTheSnoozeEndsThenRemindsOnce() {
        var state = ReminderState()
        let session = waiting("a", since: noon)
        #expect(planner.due(sessions: [session], state: &state, now: noon + 15 * minute).count == 1)

        state.snooze("a", .until(noon + 75 * minute))
        let sent = timeline(planner, sessions: { _ in [session] }, at: [20 * minute, 74 * minute, 75 * minute, 76 * minute, 119 * minute, 2 * hour], state: &state)
        // Silent while snoozed, one reminder when it ends, then the ladder carries on.
        #expect(sent == [[], [], ["session-a"], [], [], ["session-a+sound"]])
        #expect(state.snoozes.isEmpty)
    }

    @Test func aSnoozeSwallowsTheStepsThatFallInsideIt() {
        var state = ReminderState()
        let session = waiting("a", since: noon)
        state.snooze("a", .until(noon + 3 * hour))
        let sent = timeline(planner, sessions: { _ in [session] }, at: [15 * minute, 2 * hour, 3 * hour, 3 * hour + 60, 6 * hour], state: &state)
        #expect(sent == [[], [], ["session-a+sound"], [], ["session-a+sound"]])
    }

    @Test func untilChangeLastsWhileTheSameThingIsPendingAndEndsOnANewQuestion() {
        var state = ReminderState()
        state.snooze("a", .untilChange(waitingSince: noon))
        let sent = timeline(planner, sessions: { now in
            [waiting("a", since: now < noon + 5 * hour ? noon : noon + 5 * hour)]
        }, at: [15 * minute, 2 * hour, 4 * hour + 59 * minute, 5 * hour + 14 * minute, 5 * hour + 15 * minute], state: &state)
        // Nothing for the snoozed wait however long it lasts; the new question gets a fresh ladder.
        #expect(sent == [[], [], [], [], ["session-a"]])
        #expect(state.snoozes.isEmpty)
    }

    @Test func snoozesAreDroppedWhenTheSessionStopsWaiting() {
        var state = ReminderState()
        state.snooze("a", .until(noon + 10 * hour))
        state.snooze("gone", .untilChange(waitingSince: noon))
        _ = planner.due(sessions: [waiting("a", since: noon)], state: &state, now: noon + minute)
        #expect(state.snoozes.keys.sorted() == ["a"])
        _ = planner.due(sessions: [], state: &state, now: noon + 2 * minute)
        #expect(state.snoozes.isEmpty)
        // Waiting again later is a new wait, not a snoozed one.
        let again = planner.due(sessions: [waiting("a", since: noon + hour)], state: &state, now: noon + hour + 15 * minute)
        #expect(again.map(\.id) == ["session-a"])
    }

    @Test func tomorrowMorningIsNineOClockOnTheNextDay() {
        // Asked at 23:30 and at 00:30: both mean the coming calendar day's 09:00 after today.
        let late = noon + 11.5 * hour
        #expect(Snooze.tomorrow(after: late, calendar: utc) == .until(noon + 21 * hour))
        #expect(Snooze.tomorrow(after: noon, calendar: utc) == .until(noon + 21 * hour))
        #expect(Snooze.tomorrow(at: 7, after: noon, calendar: utc) == .until(noon + 19 * hour))
    }
}

@Suite struct ReminderQuietHoursTests {
    /// Quiet from 22:00 to 07:00, digest at 09:00.
    let planner = ReminderPlanner(
        settings: ReminderSettings(quietHours: QuietHours(startMinute: 22 * 60, endMinute: 7 * 60), digestMinute: 9 * 60),
        calendar: utc)

    @Test func knowsWhetherATimeIsQuietIncludingAcrossMidnight() {
        let overnight = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        #expect(!overnight.contains(noon, calendar: utc))
        #expect(overnight.contains(noon + 10 * hour, calendar: utc))          // 22:00
        #expect(overnight.contains(noon + 14 * hour, calendar: utc))          // 02:00
        #expect(overnight.contains(noon + 19 * hour - 60, calendar: utc))     // 06:59
        #expect(!overnight.contains(noon + 19 * hour, calendar: utc))         // 07:00
        let lunch = QuietHours(startMinute: 12 * 60, endMinute: 13 * 60)
        #expect(lunch.contains(noon, calendar: utc))
        #expect(!lunch.contains(noon + hour, calendar: utc))
        #expect(!QuietHours(startMinute: 300, endMinute: 300).contains(noon, calendar: utc))
    }

    @Test func holdsRemindersDuringQuietHoursAndSendsOneWhenTheyEnd() {
        var state = ReminderState()
        state.lastDigestDay = "2026-10-08"
        // Starts waiting at 21:50; the 15-minute step falls at 22:05, inside quiet hours.
        let session = waiting("a", since: noon + 9 * hour + 50 * minute)
        let sent = timeline(planner, sessions: { _ in [session] }, at: [
            10 * hour + 5 * minute,   // 22:05 quiet
            12 * hour,                // 00:00 quiet, second step also due by now
            18 * hour + 59 * minute,  // 06:59 quiet
            19 * hour,                // 07:00 quiet hours end
            19 * hour + 60,
        ], state: &state)
        #expect(sent == [[], [], [], ["session-a+sound"], []])
    }

    @Test func sendsTheDigestOnceADayAtOrAfterItsTime() {
        var state = ReminderState()
        // Already reminded, so only the digest is in play.
        let sessions = [waiting("a", since: noon - 3 * 24 * hour), waiting("b", since: noon - hour)]
        _ = ReminderPlanner(settings: ReminderSettings(digestMinute: nil), calendar: utc).due(sessions: sessions, state: &state, now: noon - 4 * hour)

        let digests = [-3.5 * hour, -3 * hour, -3 * hour + 60, 0, 21 * hour - 60, 21 * hour].map { offset -> [String] in
            planner.due(sessions: sessions, state: &state, now: noon + offset).filter { $0.kind == .digest }.map(\.body)
        }
        // 08:30 too early; 09:00 sent; not again that day; sent again at 09:00 the next day.
        #expect(digests[0] == [])
        #expect(digests[1] == ["2 sessions are waiting on you, the oldest for 2d"])
        #expect(digests[2] == [] && digests[3] == [] && digests[4] == [])
        #expect(digests[5] == ["2 sessions are waiting on you, the oldest for 3d"])
    }

    @Test func theDigestLeavesSnoozedSessionsOut() {
        let sessions = [waiting("a", since: noon - 5 * hour), waiting("b", since: noon - 30 * minute)]
        var state = ReminderState()
        state.snooze("a", .until(noon + 5 * hour))
        let digest = planner.due(sessions: sessions, state: &state, now: noon).first { $0.kind == .digest }
        #expect(digest?.body == "1 session is waiting on you, the oldest for 30m")

        var all = ReminderState()
        all.snooze("a", .until(noon + 5 * hour))
        all.snooze("b", .untilChange(waitingSince: noon - 30 * minute))
        #expect(!planner.due(sessions: sessions, state: &all, now: noon).contains { $0.kind == .digest })
    }

    @Test func catchesUpOnTheDigestWhenStartedLateAndSkipsItWhenNothingWaits() {
        var late = ReminderState()
        let one = [waiting("a", since: noon - 30 * minute)]
        // First run of the day at noon: the 09:00 digest is still owed.
        #expect(planner.due(sessions: one, state: &late, now: noon).contains { $0.body == "1 session is waiting on you, the oldest for 30m" })

        var empty = ReminderState()
        #expect(planner.due(sessions: [], state: &empty, now: noon).isEmpty)
        // The day is used up, so a session that blocks afterwards gets no late digest.
        #expect(!planner.due(sessions: one, state: &empty, now: noon + minute).contains { $0.kind == .digest })
    }
}

@Suite struct ReminderStateTests {
    @Test func aRestartDoesNotRepeatWhatWasAlreadySent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-reminders-\(UUID().uuidString)")
        let url = ReminderState.fileURL(in: directory)
        let planner = ReminderPlanner(settings: ReminderSettings(digestMinute: 9 * 60), calendar: utc)
        let session = waiting("a", since: noon)

        var state = ReminderState.load(from: url)
        #expect(state == ReminderState())
        #expect(planner.due(sessions: [session], state: &state, now: noon + 15 * minute).count == 2) // step + digest
        state.snooze("b", .until(noon + hour))
        try state.save(to: url)

        // A new process: only the file.
        var restarted = ReminderState.load(from: url)
        #expect(restarted == state)
        #expect(restarted.snoozes["b"] == .until(noon + hour))
        #expect(planner.due(sessions: [session], state: &restarted, now: noon + 16 * minute).isEmpty)
        #expect(planner.due(sessions: [session], state: &restarted, now: noon + 2 * hour).map(\.id) == ["session-a"])
    }

    @Test func aWaitIsRecognisedAfterItsTimePassesThroughAFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-reminders-\(UUID().uuidString)")
        let url = ReminderState.fileURL(in: directory)
        let planner = ReminderPlanner(settings: ReminderSettings(digestMinute: nil), calendar: utc)
        // A clock reading with more precision than the file keeps.
        let since = noon + 0.123456789
        let session = waiting("a", since: since)

        var state = ReminderState()
        #expect(planner.due(sessions: [session], state: &state, now: noon + 15 * minute + 1).count == 1)
        state.snooze("b", .untilChange(waitingSince: since))
        try state.save(to: url)

        var reloaded = ReminderState.load(from: url)
        // Same wait: nothing is re-sent, and the until-change snooze still holds.
        #expect(planner.due(sessions: [session, waiting("b", since: since)], state: &reloaded, now: noon + 16 * minute + 1).isEmpty)
        #expect(reloaded.snoozes["b"] != nil)
        #expect(Snooze.sameWait(since, since + 0.4))
        #expect(!Snooze.sameWait(since, since + 5))
        #expect(!Snooze.sameWait(nil, since))
    }

    @Test func aBrokenFileMeansAFreshStartNotACrash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-reminders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = ReminderState.fileURL(in: directory)
        try Data("{ not json".utf8).write(to: url)
        #expect(ReminderState.load(from: url) == ReminderState())
    }
}
