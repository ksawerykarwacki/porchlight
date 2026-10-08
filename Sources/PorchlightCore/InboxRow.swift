import Foundation

/// What one inbox row says, worked out once so every frontend shows the same thing.
public struct InboxRow: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// Waiting for an answer to a question.
        case question
        /// Waiting for the user to approve a tool call.
        case approval
        /// Waiting, but the job file says nothing more specific.
        case waiting
        case working
        case done
        case unknown
    }

    public let id: String
    public let title: String
    public let repo: String
    /// The Claude worktree the session works in, if any.
    public let worktree: String?
    /// "repo" or "repo / worktree", for places that take one line of text.
    public let place: String
    /// A waiting session that has waited past the overdue threshold.
    public let isOverdue: Bool
    /// Reminders for this session are paused, so it does not light the menu-bar icon either.
    public let isSnoozed: Bool
    /// "waiting 3h" for blocked sessions, otherwise how long ago anything happened.
    public let age: String?
    public let kind: Kind
    /// The question, the command awaiting approval, or the raw need. Nil when nothing is known.
    public let detail: String?
    /// The tool a pending approval is for, such as "Bash".
    public let tool: String?
    /// Choices offered with a question, in order, without the "(Recommended)" marker.
    public let options: [String]
    /// Which of `options` Claude recommends, if it marked one.
    public let recommendedOption: Int?
    public let suggestedReply: String?

    public init(session: Session, snooze: Snooze? = nil, overdueAfter: TimeInterval = MenuBarStatus.defaultOverdueAfter, now: Date = Date()) {
        isSnoozed = session.needsHuman && (snooze?.isActive(waitingSince: session.waitingSince, now: now) ?? false)
        id = session.id
        title = session.name
        let location = session.location
        repo = location.repoName
        worktree = location.worktreeName
        place = location.worktreeName.map { "\(location.repoName) / \($0)" } ?? location.repoName
        isOverdue = session.waitingSince.map { now.timeIntervalSince($0) >= overdueAfter } ?? false

        var tool: String?
        var detail: String?
        switch session.summary.state {
        case .blocked:
            switch session.needs {
            case .question(let text):
                kind = .question
                // The structured question is cleaner than `needs`, which appends the options.
                detail = session.questions.first?.question ?? text
            case .approval(let name, let command):
                kind = .approval
                tool = name
                detail = command
            case .other(let text):
                kind = session.summary.waitingFor == "permission prompt" ? .approval : .waiting
                detail = text
            case nil:
                kind = session.summary.waitingFor == "permission prompt" ? .approval : .waiting
            }
            let waited = Age.short(since: session.waitingSince, now: now).map { "waiting \($0)" }
            age = isSnoozed ? (waited.map { "snoozed, \($0)" } ?? "snoozed") : waited
        case .working:
            kind = .working
            age = Age.short(since: session.summary.startedAt, now: now).map { "started \($0) ago" }
        case .done:
            kind = .done
            age = Age.short(since: session.lastActivity, now: now).map { $0 == "just now" ? $0 : "\($0) ago" }
        case .unknown(let raw):
            kind = .unknown
            detail = raw.isEmpty ? nil : "state: \(raw)"
            age = nil
        }
        self.tool = tool
        self.detail = detail.map(Self.singleLine)
        let labels = session.questions.first?.options.map(\.label) ?? []
        let marker = "(Recommended)"
        recommendedOption = labels.firstIndex { $0.localizedCaseInsensitiveContains(marker) }
        options = labels.map {
            $0.replacingOccurrences(of: marker, with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        }
        suggestedReply = session.suggestedReply
    }

    /// What the row's snooze menu offers: ways to pause, or the way back when already paused.
    public var snoozeChoices: [SnoozeChoice] {
        isSnoozed ? [.wake, .hour, .tomorrow, .untilChange] : [.hour, .tomorrow, .untilChange]
    }

    /// Collapses whitespace so a multi-line question or command fits a row.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension InboxGroups {
    /// The groups as titled sections of rows, leaving out empty ones.
    public func sections(now: Date = Date(), snoozes: [String: Snooze] = [:]) -> [(title: String, rows: [InboxRow])] {
        [("Needs you", needsYou), ("Working", working), ("Recently done", recentlyDone), ("Other", other)]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, rows: $0.1.map { InboxRow(session: $0, snooze: snoozes[$0.id], now: now) }) }
    }
}

extension StoreSnapshot {
    /// One sentence for a banner when the snapshot is stale; nil when it is fresh.
    public func staleNotice(now: Date = Date()) -> String? {
        guard let problem else { return nil }
        let reason: String
        switch problem {
        case .claudeNotFound: reason = "The claude command was not found."
        case .cliFailed: reason = "The claude command failed."
        case .invalidOutput: reason = "The claude command printed something unexpected."
        case .timedOut: reason = "The claude command did not answer in time."
        case .other: reason = "Sessions could not be read."
        }
        guard let fetchedAt else { return reason }
        let age = Age.short(since: fetchedAt, now: now) ?? "a while"
        return "\(reason) Showing sessions from \(age == "just now" ? "a moment" : age) ago."
    }
}

/// What the menu-bar icon says at a glance.
public enum MenuBarStatus: Sendable, Equatable {
    /// Nothing is waiting.
    case idle
    /// Sessions are waiting, none for long.
    case waiting(count: Int)
    /// At least one session has waited past the threshold.
    case overdue(count: Int)

    /// The default threshold matches the reminder ladder's second step, where sound starts.
    public static let defaultOverdueAfter: TimeInterval = 2 * 3600

    /// Snoozed sessions are left out: the user has already answered "not now" for them, so they
    /// neither light the lantern nor count.
    public init(
        snapshot: StoreSnapshot, snoozes: [String: Snooze] = [:],
        overdueAfter: TimeInterval = MenuBarStatus.defaultOverdueAfter, now: Date = Date()
    ) {
        let waiting = snapshot.sessions.filter { session in
            session.needsHuman && !(snoozes[session.id]?.isActive(waitingSince: session.waitingSince, now: now) ?? false)
        }
        guard !waiting.isEmpty else {
            self = .idle
            return
        }
        let longest = waiting.compactMap(\.waitingSince).map { now.timeIntervalSince($0) }.max() ?? 0
        self = longest >= overdueAfter ? .overdue(count: waiting.count) : .waiting(count: waiting.count)
    }

    public var count: Int {
        switch self {
        case .idle: 0
        case .waiting(let count), .overdue(let count): count
        }
    }

    /// The number shown beside the icon: only from two up, because a lit lantern on its own
    /// already says that one session is waiting.
    public var badge: String? {
        count >= 2 ? String(count) : nil
    }

    /// For screen readers and the tooltip, so colour is never the only signal.
    public var summary: String {
        switch self {
        case .idle: "Nothing is waiting on you"
        case .waiting(1): "1 session is waiting on you"
        case .waiting(let count): "\(count) sessions are waiting on you"
        case .overdue(1): "1 session is waiting on you, for a long time"
        case .overdue(let count): "\(count) sessions are waiting on you, at least one for a long time"
        }
    }
}
