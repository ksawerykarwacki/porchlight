import Foundation

/// A daily window in which nothing is sent, given in minutes after midnight. It may wrap past
/// midnight (22:00 to 07:00).
public struct QuietHours: Codable, Sendable, Equatable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int, endMinute: Int) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard startMinute != endMinute else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return startMinute < endMinute
            ? (startMinute..<endMinute).contains(minute)
            : minute >= startMinute || minute < endMinute
    }
}

public struct ReminderSettings: Codable, Sendable, Equatable {
    /// When to remind, as seconds after the session started waiting. The default leaves the first
    /// minutes to Claude Code's own notification rather than doubling it.
    public var ladder: [TimeInterval]
    /// After the last ladder step, remind again this often. Nil stops after the ladder.
    public var repeatEvery: TimeInterval?
    /// Reminders for sessions that have waited at least this long also play a sound.
    public var soundAfter: TimeInterval
    public var quietHours: QuietHours?
    /// Minutes after midnight for the daily "N sessions waiting" summary. Nil turns it off.
    public var digestMinute: Int?
    /// Leave the question out of the notification text (lock screen, screen sharing).
    public var hideDetails: Bool

    public init(
        ladder: [TimeInterval] = [15 * 60, 2 * 3600],
        repeatEvery: TimeInterval? = 4 * 3600,
        soundAfter: TimeInterval = 2 * 3600,
        quietHours: QuietHours? = nil,
        digestMinute: Int? = 9 * 60,
        hideDetails: Bool = false
    ) {
        self.ladder = ladder.filter { $0 >= 0 }.sorted()
        self.repeatEvery = repeatEvery.flatMap { $0 > 0 ? $0 : nil }
        self.soundAfter = soundAfter
        self.quietHours = quietHours
        self.digestMinute = digestMinute
        self.hideDetails = hideDetails
    }

    /// How many reminder moments have passed for a session that has waited `waited` seconds.
    public func stepsDue(afterWaiting waited: TimeInterval) -> Int {
        guard waited >= 0 else { return 0 }
        var count = ladder.filter { $0 <= waited }.count
        if count == ladder.count, let repeatEvery {
            count += Int((waited - (ladder.last ?? 0)) / repeatEvery)
        }
        return count
    }
}

/// A user's "not now" for one session.
public enum Snooze: Codable, Sendable, Equatable {
    /// Silent until this moment, then one reminder.
    case until(Date)
    /// Silent for as long as the session keeps waiting on the same thing. The date is when that
    /// wait started; a new question or approval starts a new wait and ends the snooze.
    case untilChange(waitingSince: Date)

    /// Whether two "waiting since" times are the same wait. Times pass through files at
    /// millisecond precision, so they are compared with a tolerance, never for exact equality.
    public static func sameWait(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.timeIntervalSince(b)) < 1
    }

    /// Whether this snooze is in force for a session that has waited since `waitingSince`.
    public func isActive(waitingSince: Date?, now: Date) -> Bool {
        switch self {
        case .until(let end): end > now
        case .untilChange(let snoozedWait): Snooze.sameWait(snoozedWait, waitingSince)
        }
    }

    /// The next occurrence of an hour of the day strictly after `now`'s day: "tomorrow 09:00".
    public static func tomorrow(at hour: Int = 9, after now: Date, calendar: Calendar) -> Snooze {
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
        return .until(calendar.date(byAdding: .hour, value: hour, to: startOfTomorrow) ?? startOfTomorrow)
    }
}

/// The ways to say "not now" that the inbox and notifications offer.
public enum SnoozeChoice: String, Sendable, CaseIterable {
    case hour
    case tomorrow
    case untilChange
    /// Ends a snooze.
    case wake

    public var title: String {
        switch self {
        case .hour: "For 1 hour"
        case .tomorrow: "Until tomorrow morning"
        case .untilChange: "Until it asks something new"
        case .wake: "Stop snoozing"
        }
    }

    /// The snooze this choice means for a session, or nil for `wake` and for an until-change
    /// snooze of a session whose wait time is unknown.
    public func snooze(for session: Session, now: Date, calendar: Calendar = .current) -> Snooze? {
        switch self {
        case .hour: .until(now.addingTimeInterval(3600))
        case .tomorrow: .tomorrow(after: now, calendar: calendar)
        case .untilChange: session.waitingSince.map { .untilChange(waitingSince: $0) }
        case .wake: nil
        }
    }
}

/// What has already been sent and what is snoozed. Saved to disk so a restart repeats nothing.
public struct ReminderState: Codable, Sendable, Equatable {
    struct Sent: Codable, Sendable, Equatable {
        var waitingSince: Date
        var steps: Int
    }

    var sent: [String: Sent] = [:]
    public internal(set) var snoozes: [String: Snooze] = [:]
    var lastDigestDay: String?

    public init() {}

    public mutating func snooze(_ sessionID: String, _ snooze: Snooze) {
        snoozes[sessionID] = snooze
    }

    public mutating func clearSnooze(_ sessionID: String) {
        snoozes[sessionID] = nil
    }

    public static func fileURL(in stateDirectory: URL = PorchlightPaths.stateDirectory()) -> URL {
        stateDirectory.appendingPathComponent("reminders.json")
    }

    public static func load(from url: URL = ReminderState.fileURL()) -> ReminderState {
        guard let data = try? Data(contentsOf: url) else { return ReminderState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode(ReminderState.self, from: data)) ?? ReminderState()
    }

    public func save(to url: URL = ReminderState.fileURL()) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// One notification to deliver.
public struct Reminder: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case session(id: String)
        case digest
    }

    public let kind: Kind
    public let title: String
    /// Where the session lives; empty for the digest.
    public var subtitle = ""
    public let body: String
    public let withSound: Bool
    /// The session came with a reply Claude suggested, which the user can copy.
    public var offersReply = false

    public init(kind: Kind, title: String, subtitle: String = "", body: String, withSound: Bool, offersReply: Bool = false) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.withSound = withSound
        self.offersReply = offersReply
    }

    /// Stable per session, so a newer reminder replaces the older one instead of stacking.
    public var id: String {
        switch kind {
        case .session(let id): "session-\(id)"
        case .digest: "digest"
        }
    }
}

/// Decides which reminders are due. Pure: sessions, saved state and a clock in, reminders out.
public struct ReminderPlanner: Sendable {
    public var settings: ReminderSettings
    public var calendar: Calendar

    public init(settings: ReminderSettings = ReminderSettings(), calendar: Calendar = .current) {
        self.settings = settings
        self.calendar = calendar
    }

    /// Call on every refresh. Returns what to deliver now and records it in `state`.
    public func due(sessions: [Session], state: inout ReminderState, now: Date) -> [Reminder] {
        let waiting = sessions.filter(\.needsHuman)
        let waitingIDs = Set(waiting.map(\.id))
        // A session that stopped waiting has nothing left to remember.
        state.sent = state.sent.filter { waitingIDs.contains($0.key) }
        state.snoozes = state.snoozes.filter { waitingIDs.contains($0.key) }

        let quiet = settings.quietHours?.contains(now, calendar: calendar) ?? false
        var reminders: [Reminder] = []

        for session in waiting {
            guard let since = session.waitingSince else { continue }
            if !Snooze.sameWait(state.sent[session.id]?.waitingSince, since) {
                // A new wait: a different question, or the first time this session is seen.
                state.sent[session.id] = ReminderState.Sent(waitingSince: since, steps: 0)
            }
            let waited = now.timeIntervalSince(since)
            let stepsDue = settings.stepsDue(afterWaiting: waited)

            var snoozeEnded = false
            switch state.snoozes[session.id] {
            case .until(let end) where end > now:
                continue
            case .until:
                snoozeEnded = true
            case .untilChange(let snoozedWait) where Snooze.sameWait(snoozedWait, since):
                continue
            case .untilChange:
                state.snoozes[session.id] = nil
            case nil:
                break
            }

            let alreadySent = state.sent[session.id]?.steps ?? 0
            guard snoozeEnded || stepsDue > alreadySent else { continue }
            // During quiet hours nothing is recorded as sent, so it goes out when they end.
            guard !quiet else { continue }

            state.snoozes[session.id] = nil
            // However many steps were missed, one reminder covers them.
            state.sent[session.id]?.steps = stepsDue
            reminders.append(reminder(for: session, waited: waited, now: now))
        }

        // A snoozed session is one the user has already said "not now" to: it stays out of the
        // summary too.
        let unsnoozed = waiting.filter { session in
            !(state.snoozes[session.id]?.isActive(waitingSince: session.waitingSince, now: now) ?? false)
        }
        if let digest = digest(waiting: unsnoozed, state: &state, now: now, quiet: quiet) {
            reminders.append(digest)
        }
        return reminders
    }

    private func reminder(for session: Session, waited: TimeInterval, now: Date) -> Reminder {
        let row = InboxRow(session: session, now: now)
        let age = Age.short(since: session.waitingSince, now: now).map { $0 == "just now" ? "" : " for \($0)" } ?? ""
        let fallback: String
        switch row.kind {
        case .approval: fallback = "Waiting\(age) for your approval"
        default: fallback = "Waiting\(age) for your input"
        }
        var body = fallback
        if !settings.hideDetails, let detail = row.detail {
            body = row.kind == .approval ? "Approve \(row.tool ?? "tool"): \(detail)" : detail
        }
        return Reminder(
            kind: .session(id: session.id),
            title: session.name,
            subtitle: row.place,
            body: body,
            withSound: waited >= settings.soundAfter,
            offersReply: session.suggestedReply != nil)
    }

    private func digest(waiting: [Session], state: inout ReminderState, now: Date, quiet: Bool) -> Reminder? {
        guard let digestMinute = settings.digestMinute, !quiet else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard (parts.hour ?? 0) * 60 + (parts.minute ?? 0) >= digestMinute else { return nil }
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard state.lastDigestDay != day else { return nil }
        // The day is used up even when nothing is waiting, so a session that blocks a minute
        // later gets its own reminders rather than a late digest.
        state.lastDigestDay = day
        guard !waiting.isEmpty else { return nil }

        let oldest = waiting.compactMap(\.waitingSince).min()
        let age = Age.short(since: oldest, now: now).flatMap { $0 == "just now" ? nil : ", the oldest for \($0)" } ?? ""
        let count = waiting.count == 1 ? "1 session is waiting on you" : "\(waiting.count) sessions are waiting on you"
        return Reminder(kind: .digest, title: "Porchlight", body: count + age, withSound: false)
    }
}
