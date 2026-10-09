import Foundation
import PorchlightCore
import UserNotifications

/// How a reminder is shown, as plain data, so it can be checked without posting anything.
public struct NotificationPlan: Sendable, Equatable {
    public enum Category: String, Sendable, CaseIterable {
        /// A waiting session: Open, Snooze.
        case session = "porchlight.session"
        /// A waiting session that came with a suggested reply: also Copy reply.
        case sessionWithReply = "porchlight.session.reply"
        case digest = "porchlight.digest"
    }

    public enum Button: String, Sendable, CaseIterable {
        case open = "porchlight.open"
        case snoozeHour = "porchlight.snooze.1h"
        case snoozeTomorrow = "porchlight.snooze.tomorrow"
        case copyReply = "porchlight.copy-reply"

        public var title: String {
            switch self {
            case .open: "Open"
            case .snoozeHour: "Snooze 1 hour"
            case .snoozeTomorrow: "Snooze until tomorrow"
            case .copyReply: "Copy suggested reply"
            }
        }
    }

    /// How hard the notification may interrupt.
    public enum Level: String, Sendable, CaseIterable {
        /// An ordinary notification: a Focus holds it back.
        case active
        /// May be shown during a Focus, if macOS allows the app that level.
        case timeSensitive
    }

    /// Reused for the same session, so a newer reminder replaces the older one.
    public let identifier: String
    public let category: Category
    public let title: String
    public let subtitle: String
    public let body: String
    public let playsSound: Bool
    public let level: Level
    public let sessionID: String?

    public init(_ reminder: Reminder) {
        identifier = reminder.id
        title = reminder.title
        subtitle = reminder.subtitle
        body = reminder.body
        playsSound = reminder.withSound
        switch reminder.kind {
        case .session(let id):
            sessionID = id
            category = reminder.offersReply ? .sessionWithReply : .session
            level = reminder.timeSensitive ? .timeSensitive : .active
        case .digest:
            sessionID = nil
            category = .digest
            // A summary is never urgent, whatever the reminder says.
            level = .active
        }
    }

    /// The notification as macOS takes it. Building it posts nothing. Pass `false` when macOS
    /// has said the app may not use the time-sensitive level: the reminder then goes out as an
    /// ordinary one rather than asking for something the app was refused.
    public func content(timeSensitiveAllowed: Bool = true) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.categoryIdentifier = category.rawValue
        content.threadIdentifier = identifier
        if playsSound { content.sound = .default }
        content.interruptionLevel = level == .timeSensitive && timeSensitiveAllowed ? .timeSensitive : .active
        if let sessionID { content.userInfo = ["sessionID": sessionID] }
        return content
    }

    public static func buttons(for category: Category) -> [Button] {
        switch category {
        case .session: [.open, .snoozeHour, .snoozeTomorrow]
        case .sessionWithReply: [.open, .copyReply, .snoozeHour, .snoozeTomorrow]
        case .digest: []
        }
    }

    /// What a response means. `actionIdentifier` is a button's raw value, or nil when the
    /// notification itself was clicked.
    public static func action(button actionIdentifier: String?, sessionID: String?, now: Date = Date(), calendar: Calendar = .current) -> ReminderAction? {
        guard let sessionID else { return .showInbox }
        guard let actionIdentifier, let button = Button(rawValue: actionIdentifier) else {
            // Clicking the notification body is the same as Open.
            return .open(sessionID: sessionID)
        }
        switch button {
        case .open: return .open(sessionID: sessionID)
        case .copyReply: return .copyReply(sessionID: sessionID)
        case .snoozeHour: return .snooze(sessionID: sessionID, seconds: 3600)
        case .snoozeTomorrow:
            guard case .until(let end) = Snooze.tomorrow(after: now, calendar: calendar) else { return nil }
            return .snooze(sessionID: sessionID, seconds: end.timeIntervalSince(now))
        }
    }
}

/// Whether macOS lets this copy of the app send time-sensitive notifications, as it reports it.
public enum TimeSensitiveSupport: String, Sendable, CaseIterable {
    /// Not asked yet, or not running as an app.
    case unknown
    /// The app may not use the level at all: it was not signed with the entitlement for it.
    case notSupported
    /// The app may, and the user has turned it off in System Settings.
    case disabled
    case enabled

    public init(_ setting: UNNotificationSetting) {
        switch setting {
        case .notSupported: self = .notSupported
        case .disabled: self = .disabled
        case .enabled: self = .enabled
        @unknown default: self = .unknown
        }
    }

    /// What to tell someone who has asked for time-sensitive reminders, or nil when they will
    /// get them (or nothing is known yet).
    public var note: String? {
        switch self {
        case .unknown, .enabled: nil
        case .notSupported:
            "This build cannot send time-sensitive notifications: macOS only allows them from a signed release. Until then these reminders arrive as ordinary ones."
        case .disabled:
            "Time-sensitive notifications are turned off for Porchlight. Turn them on in System Settings > Notifications."
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stored = TimeSensitiveSupport.unknown

    /// What macOS last reported to this process. Kept here, not passed along, because the
    /// settings page that shows it and the delivery that learns it do not know each other.
    public static var current: TimeSensitiveSupport {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Delivers reminders as macOS notifications.
///
/// Notifications need an app bundle, so this does nothing when run as a bare executable, and
/// nothing when `PORCHLIGHT_NO_NOTIFICATIONS` is set.
public final class UserNotificationDelivery: NSObject, ReminderDelivery, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private let onAction: @Sendable (ReminderAction) -> Void
    private let enabled: Bool
    private let lock = NSLock()
    private var askedForPermission = false
    private var storedProblem: String?
    private var recordedLevel: String?

    public init(onAction: @escaping @Sendable (ReminderAction) -> Void) {
        self.onAction = onAction
        // Only inside a real app bundle: the notification centre is unusable, and can crash, in a
        // bare executable or a test runner.
        self.enabled = Bundle.main.bundleURL.pathExtension == "app"
            && Bundle.main.bundleIdentifier != nil
            && ProcessInfo.processInfo.environment["PORCHLIGHT_NO_NOTIFICATIONS"] == nil
        super.init()
        guard enabled else {
            if ProcessInfo.processInfo.environment["PORCHLIGHT_NO_NOTIFICATIONS"] != nil {
                problem = "Notifications are switched off by PORCHLIGHT_NO_NOTIFICATIONS."
            } else {
                problem = "Notifications need the app bundle; this is running from \(Bundle.main.bundleURL.path) (identifier \(Bundle.main.bundleIdentifier ?? "none"))."
            }
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(Set(NotificationPlan.Category.allCases.map { category in
            UNNotificationCategory(
                identifier: category.rawValue,
                actions: NotificationPlan.buttons(for: category).map {
                    // Open brings the terminal forward; the others act in the background.
                    UNNotificationAction(identifier: $0.rawValue, title: $0.title, options: $0 == .open ? [.foreground] : [])
                },
                intentIdentifiers: [])
        }))
        // Reading the settings never prompts, so it is safe at launch: the settings page can say
        // at once whether time-sensitive reminders will work.
        Task { [weak self] in
            let settings = await center.notificationSettings()
            self?.record(settings)
        }
    }

    /// Notes what macOS allows this app, in memory for the settings page and on disk for a bug
    /// report. Only ever called inside the app bundle.
    private func record(_ settings: UNNotificationSettings) {
        let support = TimeSensitiveSupport(settings.timeSensitiveSetting)
        TimeSensitiveSupport.current = support
        let url = PorchlightPaths.stateDirectory().appendingPathComponent("notification-level.txt")
        let text = "timeSensitive: \(support.rawValue)\nauthorization: \(Self.name(settings.authorizationStatus))\n"
        // Asked again before every reminder; written only when the answer changes.
        let changed = lock.withLock {
            defer { recordedLevel = text }
            return recordedLevel != text
        }
        guard changed else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url, options: .atomic)
    }

    private static func name(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    public var isEnabled: Bool { enabled }

    /// Why reminders are not reaching the screen, in words, or nil when they can.
    public private(set) var problem: String? {
        get { lock.withLock { storedProblem } }
        set {
            lock.withLock { storedProblem = newValue }
            // Kept on disk too, so a bug report can say what happened. Only the app itself
            // writes it: a test runner or a bare executable must not touch the user's folder.
            guard Bundle.main.bundleURL.pathExtension == "app" else { return }
            let url = PorchlightPaths.stateDirectory().appendingPathComponent("notification-status.txt")
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data((newValue ?? "ok").utf8).write(to: url, options: .atomic)
        }
    }

    /// Asks for permission the first time something is actually due, not at launch.
    private func permissionGranted() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        record(settings)
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            problem = nil
            return true
        case .denied:
            problem = "Notifications are turned off for Porchlight. Turn them on in System Settings > Notifications."
            return false
        default:
            let alreadyAsked = lock.withLock {
                defer { askedForPermission = true }
                return askedForPermission
            }
            guard !alreadyAsked else { return false }
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                problem = granted ? nil : "Notifications were not allowed for Porchlight."
                return granted
            } catch {
                problem = "macOS refused to let Porchlight ask for notifications: \(error.localizedDescription)"
                return false
            }
        }
    }

    public func deliver(_ reminder: Reminder) async {
        guard enabled, await permissionGranted() else { return }
        let plan = NotificationPlan(reminder)
        // What macOS allows was read a moment ago, with the permission.
        let content = plan.content(timeSensitiveAllowed: TimeSensitiveSupport.current != .notSupported)
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: plan.identifier, content: content, trigger: nil))
        } catch {
            problem = "macOS did not accept a notification: \(error.localizedDescription)"
        }
    }

    public func withdraw(reminderIDs: [String]) async {
        guard enabled else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: reminderIDs)
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show reminders even while Porchlight's own panel is open.
        completionHandler([.banner, .list, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        let identifier = response.actionIdentifier
        guard identifier != UNNotificationDismissActionIdentifier else { return }
        let button = identifier == UNNotificationDefaultActionIdentifier ? nil : identifier
        let sessionID = response.notification.request.content.userInfo["sessionID"] as? String
        if let action = NotificationPlan.action(button: button, sessionID: sessionID) {
            onAction(action)
        }
    }
}
