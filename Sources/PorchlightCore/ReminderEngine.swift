import Foundation

/// Where reminders go. The macOS app delivers them as notifications; tests collect them.
public protocol ReminderDelivery: Sendable {
    func deliver(_ reminder: Reminder) async
    /// Takes back reminders that no longer apply, by `Reminder.id`.
    func withdraw(reminderIDs: [String]) async
}

/// What the user chose on a reminder.
public enum ReminderAction: Sendable, Equatable {
    case open(sessionID: String)
    case snooze(sessionID: String, seconds: TimeInterval)
    case copyReply(sessionID: String)
    /// The daily digest was clicked.
    case showInbox
}

/// Runs the planner on every refresh, delivers what is due and keeps the saved state in step.
public actor ReminderEngine {
    private let planner: ReminderPlanner
    private let delivery: any ReminderDelivery
    private let stateURL: URL
    private let now: @Sendable () -> Date
    /// Sessions that currently have a delivered reminder, so it can be withdrawn when they move on.
    private var reminded: Set<String> = []

    public init(
        planner: ReminderPlanner = ReminderPlanner(),
        delivery: any ReminderDelivery,
        stateURL: URL = ReminderState.fileURL(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.planner = planner
        self.delivery = delivery
        self.stateURL = stateURL
        self.now = now
    }

    /// Call with every snapshot from the store. Returns what was delivered.
    @discardableResult
    public func process(_ snapshot: StoreSnapshot) async -> [Reminder] {
        // Before the first successful read there is nothing to judge.
        guard snapshot.fetchedAt != nil else { return [] }
        // The file is read each time, so a snooze set from the command line takes effect.
        var state = ReminderState.load(from: stateURL)
        let before = state
        let due = planner.due(sessions: snapshot.sessions, state: &state, now: now())
        if state != before { try? state.save(to: stateURL) }

        let waiting = Set(snapshot.sessions.filter(\.needsHuman).map(\.id))
        let finished = reminded.subtracting(waiting)
        if !finished.isEmpty {
            await delivery.withdraw(reminderIDs: finished.map { "session-\($0)" }.sorted())
            reminded.subtract(finished)
        }
        for reminder in due {
            await delivery.deliver(reminder)
            if case .session(let id) = reminder.kind { reminded.insert(id) }
        }
        return due
    }

    /// Pauses reminders for a session and takes its current one off the screen.
    public func snooze(sessionID: String, _ snooze: Snooze) async {
        var state = ReminderState.load(from: stateURL)
        state.snooze(sessionID, snooze)
        try? state.save(to: stateURL)
        await delivery.withdraw(reminderIDs: ["session-\(sessionID)"])
        reminded.remove(sessionID)
    }

    public func clearSnooze(sessionID: String) {
        var state = ReminderState.load(from: stateURL)
        state.clearSnooze(sessionID)
        try? state.save(to: stateURL)
    }

    public func snoozes() -> [String: Snooze] {
        ReminderState.load(from: stateURL).snoozes
    }
}
