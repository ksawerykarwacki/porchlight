import Foundation
import PorchlightCore
import Testing
import UserNotifications

@testable import PorchlightMac

@Suite struct NotificationLevelTests {
    func reminder(_ kind: Reminder.Kind = .session(id: "a1b2c3d4"), urgent: Bool, sound: Bool = false) -> Reminder {
        Reminder(kind: kind, title: "fix flaky test", subtitle: "alpha", body: "Which timeout?", withSound: sound, timeSensitive: urgent)
    }

    @Test func aTimeSensitiveReminderAsksForTheTimeSensitiveLevel() {
        let plan = NotificationPlan(reminder(urgent: true))
        #expect(plan.level == .timeSensitive)
        #expect(plan.content().interruptionLevel == .timeSensitive)
        // Where macOS has refused the app the level, it is not asked for; the plan still says
        // what the reminder wanted.
        #expect(plan.content(timeSensitiveAllowed: false).interruptionLevel == .active)
        #expect(plan.content(timeSensitiveAllowed: false).body == "Which timeout?")
    }

    @Test func anOrdinaryReminderDoesNot() {
        let plan = NotificationPlan(reminder(urgent: false))
        #expect(plan.level == .active)
        #expect(plan.content().interruptionLevel == .active)
        // Sound is a separate matter: a loud reminder is still an ordinary one.
        #expect(NotificationPlan(reminder(urgent: false, sound: true)).content().interruptionLevel == .active)
    }

    @Test func theDigestIsNeverTimeSensitiveWhateverItIsHanded() {
        let plan = NotificationPlan(reminder(.digest, urgent: true))
        #expect(plan.level == .active)
        #expect(plan.content().interruptionLevel == .active)
    }

    @Test func theLevelChangesNothingElseAboutTheNotification() {
        let ordinary = NotificationPlan(reminder(urgent: false, sound: true)).content()
        let urgent = NotificationPlan(reminder(urgent: true, sound: true)).content()
        #expect(urgent.title == "fix flaky test" && urgent.title == ordinary.title)
        #expect(urgent.subtitle == "alpha" && urgent.subtitle == ordinary.subtitle)
        #expect(urgent.body == "Which timeout?" && urgent.body == ordinary.body)
        #expect(urgent.categoryIdentifier == "porchlight.session" && urgent.categoryIdentifier == ordinary.categoryIdentifier)
        // The same thread and session, so the urgent reminder replaces the ordinary one.
        #expect(urgent.threadIdentifier == "session-a1b2c3d4" && urgent.threadIdentifier == ordinary.threadIdentifier)
        #expect(urgent.userInfo["sessionID"] as? String == "a1b2c3d4")
        #expect(urgent.sound != nil && ordinary.sound != nil)
        #expect(NotificationPlan(reminder(urgent: true)).content().sound == nil)
    }

    @Test func whatMacOSReportsBecomesWordsForTheSettingsPage() {
        #expect(TimeSensitiveSupport(.notSupported) == .notSupported)
        #expect(TimeSensitiveSupport(.disabled) == .disabled)
        #expect(TimeSensitiveSupport(.enabled) == .enabled)
        // Nothing to say when it works or is not known yet.
        #expect(TimeSensitiveSupport.enabled.note == nil)
        #expect(TimeSensitiveSupport.unknown.note == nil)
        #expect(TimeSensitiveSupport.notSupported.note?.contains("signed release") == true)
        #expect(TimeSensitiveSupport.disabled.note?.contains("System Settings") == true)
        // The test runner is not an app: nothing has been asked, so nothing is claimed.
        #expect(TimeSensitiveSupport.current == .unknown)
    }
}
