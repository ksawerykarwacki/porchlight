import Foundation
import PorchlightCore
import Testing

@testable import PorchlightMac

@Suite struct NotificationPlanTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// 2026-10-08 12:00:00 UTC.
    let noon = Date(timeIntervalSince1970: 1_791_460_800)

    func reminder(_ kind: Reminder.Kind, sound: Bool = false, reply: Bool = false) -> Reminder {
        Reminder(kind: kind, title: "fix flaky test", subtitle: "alpha", body: "Which timeout?", withSound: sound, offersReply: reply)
    }

    @Test func aSessionReminderGetsOpenAndSnoozeButtons() {
        let plan = NotificationPlan(reminder(.session(id: "a1b2c3d4"), sound: true))
        #expect(plan.identifier == "session-a1b2c3d4")
        #expect(plan.category == .session)
        #expect(plan.title == "fix flaky test")
        #expect(plan.subtitle == "alpha")
        #expect(plan.body == "Which timeout?")
        #expect(plan.playsSound)
        #expect(plan.sessionID == "a1b2c3d4")
        #expect(NotificationPlan.buttons(for: plan.category).map(\.title) == ["Open", "Snooze 1 hour", "Snooze until tomorrow"])
    }

    @Test func copyReplyIsOfferedOnlyWhenThereIsOne() {
        let withReply = NotificationPlan(reminder(.session(id: "a"), reply: true))
        #expect(withReply.category == .sessionWithReply)
        #expect(NotificationPlan.buttons(for: withReply.category).contains(.copyReply))
        #expect(!NotificationPlan.buttons(for: .session).contains(.copyReply))
    }

    @Test func theDigestHasNoButtonsAndNoSession() {
        let plan = NotificationPlan(reminder(.digest))
        #expect(plan.identifier == "digest")
        #expect(plan.category == .digest)
        #expect(plan.sessionID == nil)
        #expect(!plan.playsSound)
        #expect(NotificationPlan.buttons(for: .digest).isEmpty)
    }

    @Test func everyCategoryAndButtonHasADistinctIdentifier() {
        #expect(Set(NotificationPlan.Category.allCases.map(\.rawValue)).count == NotificationPlan.Category.allCases.count)
        #expect(Set(NotificationPlan.Button.allCases.map(\.rawValue)).count == NotificationPlan.Button.allCases.count)
        for button in NotificationPlan.Button.allCases { #expect(!button.title.isEmpty) }
    }

    @Test func pressedButtonsMapToActions() {
        func action(_ button: NotificationPlan.Button?, session: String? = "a") -> ReminderAction? {
            NotificationPlan.action(button: button?.rawValue, sessionID: session, now: noon, calendar: calendar)
        }
        #expect(action(.open) == .open(sessionID: "a"))
        // Clicking the notification itself opens the session too.
        #expect(action(nil) == .open(sessionID: "a"))
        #expect(action(.copyReply) == .copyReply(sessionID: "a"))
        #expect(action(.snoozeHour) == .snooze(sessionID: "a", seconds: 3600))
        // From noon, tomorrow 09:00 is 21 hours away.
        #expect(action(.snoozeTomorrow) == .snooze(sessionID: "a", seconds: 21 * 3600))
        // The digest carries no session.
        #expect(action(nil, session: nil) == .showInbox)
        // An identifier this version does not know falls back to opening the session.
        #expect(NotificationPlan.action(button: "porchlight.future", sessionID: "a") == .open(sessionID: "a"))
    }

    @Test func deliveryIsSwitchedOffOutsideAnAppBundle() async {
        // The test runner is not an app bundle: nothing must be posted or asked from it.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-status-\(UUID().uuidString)")
        setenv("PORCHLIGHT_STATE_DIR", folder.path, 1)
        defer { unsetenv("PORCHLIGHT_STATE_DIR") }
        let delivery = UserNotificationDelivery { _ in }
        #expect(!delivery.isEnabled)
        #expect(delivery.problem?.contains("app bundle") == true)
        // Saying why is fine; writing into the state folder from here is not.
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await delivery.deliver(reminder(.session(id: "a")))
        await delivery.withdraw(reminderIDs: ["session-a"])
    }
}
