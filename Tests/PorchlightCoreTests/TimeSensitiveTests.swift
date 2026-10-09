import Foundation
import Testing

@testable import PorchlightCore

@Suite struct TimeSensitiveTests {
    /// Runs the planner at a series of offsets from noon and returns, for each, whether the
    /// reminders it sent were marked time-sensitive.
    func marks(_ settings: ReminderSettings, sessions: [Session], at offsets: [TimeInterval], state: inout ReminderState) -> [[String]] {
        let planner = ReminderPlanner(settings: settings, calendar: utc)
        return offsets.map { offset in
            planner.due(sessions: sessions, state: &state, now: noon + offset).map { "\($0.id)\($0.timeSensitive ? "+urgent" : "")" }
        }
    }

    @Test func offByDefaultAndNeverMarkedWhenOff() {
        #expect(ReminderSettings().timeSensitiveAfter == nil)
        var state = ReminderState()
        // The default ladder, far past any time one might choose: every reminder stays ordinary.
        let sent = marks(
            ReminderSettings(digestMinute: nil), sessions: [waiting("a", since: noon)],
            at: [15 * minute, 2 * hour, 6 * hour, 10 * hour, 30 * 24 * hour], state: &state)
        #expect(sent == [["session-a"], ["session-a"], ["session-a"], ["session-a"], ["session-a"]])
    }

    @Test func markedOnceTheWaitReachesTheSettingAndNotBefore() {
        var state = ReminderState()
        let settings = ReminderSettings(timeSensitiveAfter: 4 * hour, digestMinute: nil)
        let sent = marks(settings, sessions: [waiting("a", since: noon)], at: [
            15 * minute, 2 * hour,  // the two steps, both before four hours
            4 * hour,               // reaching the time sends nothing by itself
            6 * hour, 10 * hour,    // the repeats that follow carry the level
        ], state: &state)
        #expect(sent == [["session-a"], ["session-a"], [], ["session-a+urgent"], ["session-a+urgent"]])
    }

    @Test func theMomentItselfCountsAndTheSecondBeforeDoesNot() {
        // A step at exactly two hours, with the setting at two hours.
        let settings = ReminderSettings(ladder: [2 * hour], repeatEvery: nil, timeSensitiveAfter: 2 * hour, digestMinute: nil)
        var state = ReminderState()
        #expect(marks(settings, sessions: [waiting("a", since: noon)], at: [2 * hour], state: &state) == [["session-a+urgent"]])

        // The same step a second after the session started waiting later: 1 h 59 min 59 s in.
        let early = ReminderSettings(ladder: [2 * hour - 1], repeatEvery: nil, timeSensitiveAfter: 2 * hour, digestMinute: nil)
        state = ReminderState()
        #expect(marks(early, sessions: [waiting("a", since: noon)], at: [2 * hour - 1], state: &state) == [["session-a"]])
    }

    @Test func eachSessionIsJudgedByItsOwnWait() {
        var state = ReminderState()
        let settings = ReminderSettings(timeSensitiveAfter: hour, digestMinute: nil)
        // At noon one session has waited three hours and the other twenty minutes.
        let sessions = [waiting("old", since: noon - 3 * hour), waiting("new", since: noon - 20 * minute)]
        #expect(marks(settings, sessions: sessions, at: [0], state: &state) == [["session-old+urgent", "session-new"]])
    }

    @Test func aNewQuestionStartsOrdinaryAgain() {
        var state = ReminderState()
        let settings = ReminderSettings(timeSensitiveAfter: hour, digestMinute: nil)
        #expect(marks(settings, sessions: [waiting("a", since: noon - 5 * hour)], at: [0], state: &state) == [["session-a+urgent"]])
        // Answered, then blocked on something else at noon: its first reminder is ordinary.
        #expect(marks(settings, sessions: [waiting("a", since: noon)], at: [15 * minute], state: &state) == [["session-a"]])
    }

    @Test func theDigestIsNeverMarked() {
        var state = ReminderState()
        // Noon is past the 09:00 digest, and the session has waited far longer than the setting.
        let planner = ReminderPlanner(settings: ReminderSettings(timeSensitiveAfter: hour), calendar: utc)
        let due = planner.due(sessions: [waiting("a", since: noon - 9 * hour)], state: &state, now: noon)
        #expect(due.map(\.id) == ["session-a", "digest"])
        #expect(due.map(\.timeSensitive) == [true, false])
    }

    @Test func quietHoursStillHoldATimeSensitiveReminderBack() {
        var state = ReminderState()
        // Quiet from 11:00 to 13:00 UTC; noon is inside.
        let settings = ReminderSettings(
            timeSensitiveAfter: hour, quietHours: QuietHours(startMinute: 11 * 60, endMinute: 13 * 60), digestMinute: nil)
        let sent = marks(settings, sessions: [waiting("a", since: noon - 9 * hour)], at: [0, 30 * minute, hour, hour + 60], state: &state)
        // Nothing while it is quiet; one reminder, with the level, when the quiet ends.
        #expect(sent == [[], [], ["session-a+urgent"], []])
    }

    @Test func aReminderAfterASnoozeCarriesTheLevelItsWaitHasEarned() {
        var state = ReminderState()
        let settings = ReminderSettings(timeSensitiveAfter: 4 * hour, digestMinute: nil)
        let session = waiting("a", since: noon)
        state.snooze("a", .until(noon + 5 * hour))
        let sent = marks(settings, sessions: [session], at: [2 * hour, 4 * hour + 60, 5 * hour], state: &state)
        #expect(sent == [[], [], ["session-a+urgent"]])
    }

    @Test func zeroAndNegativeTimesMeanOff() {
        #expect(ReminderSettings(timeSensitiveAfter: 0).timeSensitiveAfter == nil)
        #expect(ReminderSettings(timeSensitiveAfter: -60).timeSensitiveAfter == nil)
        #expect(ReminderSettings(timeSensitiveAfter: .infinity).timeSensitiveAfter == nil)
        #expect(ReminderSettings(timeSensitiveAfter: 4 * hour).timeSensitiveAfter == 4 * hour)
        // A plain reminder is ordinary unless told otherwise.
        #expect(!Reminder(kind: .session(id: "a"), title: "a", body: "b", withSound: false).timeSensitive)
    }
}
