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
    /// The end of what a waiting session said last, its paragraphs kept; shown in place of
    /// `detail`, which is then only a fragment of it. `saidEnding` is its last paragraph or two.
    public let said: String?
    public let saidEnding: String?
    /// The last paragraph of `said` as one plain line: what the session asks, for places with
    /// room for a line (the palette's list, a notification).
    public let saidLine: String?
    /// Where a waiting session stands, when that says more than `detail` does. Not for an
    /// approval, which is about one command.
    public let context: String?
    /// The tool a pending approval is for, such as "Bash".
    public let tool: String?
    /// Choices offered with a question, in order, without the "(Recommended)" marker.
    public let options: [String]
    /// The asking an option would answer, when one can: see `Session.answerTarget`. A choice is
    /// tied to it, so that it is never sent to a later question.
    public let answerID: String?
    public var isAnswerable: Bool { answerID != nil }
    /// Which of `options` Claude recommends, if it marked one.
    public let recommendedOption: Int?
    public let suggestedReply: String?
    /// Waiting only because of a passing failure (a limit, a sleeping laptop, an API that was
    /// down), so trying again is likely all it needs.
    public let isRetryable: Bool
    /// The failure the session's mod will retry on the app's word, when there is one: Retry then
    /// sends through the mod instead of opening the session.
    public let retry: RetryTarget?
    /// Where a reply typed in Porchlight would go, when the session can take one.
    public let reply: ReplyTarget?
    /// What automatic retry will do about it, when that is turned on.
    public let autoRetry: AutoRetry.Standing?
    /// When a scheduled retry will be sent, in words: "now", "in a minute", "in 4 min".
    public let autoRetryWhen: String?
    /// Whether the session can be stopped, and whether it can be removed, from here.
    public let canStop: Bool
    public let canRemove: Bool
    /// Kept on purpose by the user; `isQuiet` when its reminders are off as well.
    public let isPinned: Bool
    public let isQuiet: Bool

    public init(
        session: Session, snooze: Snooze? = nil, pin: Pin? = nil, overdueAfter: TimeInterval = MenuBarStatus.defaultOverdueAfter,
        transientErrors: TransientErrors = TransientErrors(), now: Date = Date()
    ) {
        isPinned = pin != nil
        isQuiet = pin?.quiet ?? false
        isRetryable = transientErrors.offersRetry(session)
        retry = session.retryTarget
        reply = session.replyTarget
        autoRetry = session.retryTarget.flatMap { target in transientErrors.autoRetry.map { $0.standing(for: target) } }
        if case .scheduled(let at, _, _)? = autoRetry {
            let left = at.timeIntervalSince(now)
            autoRetryWhen = left <= 0 ? "now" : left < 90 ? "in a minute" : "in \(Int((left / 60).rounded())) min"
        } else {
            autoRetryWhen = nil
        }
        canStop = SessionAction.stop.applies(to: session)
        // A pinned session is one the user said to keep: it has to be unpinned before it can go.
        canRemove = pin == nil && SessionAction.remove.applies(to: session)
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
        let shown = detail.map(Self.singleLine)
        self.detail = shown
        said = kind == .waiting ? session.lastSaid : nil
        saidEnding = said.map { Self.ending(of: $0) }
        saidLine = said.flatMap { Self.lastLine(of: $0) }
        let standing = kind == .question || (kind == .waiting && said == nil) ? session.standing.map(Self.singleLine) : nil
        // Said once: not when it only repeats the question.
        context = standing.flatMap { $0.caseInsensitiveCompare(shown ?? "") == .orderedSame ? nil : $0 }
        let labels = session.questions.first?.options.map(\.label) ?? []
        let marker = "(Recommended)"
        recommendedOption = labels.firstIndex { $0.localizedCaseInsensitiveContains(marker) }
        options = labels.map {
            $0.replacingOccurrences(of: marker, with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
        }
        suggestedReply = session.suggestedReply
        answerID = session.answerTarget?.questionID
    }

    /// What the row's snooze menu offers: ways to pause, or the way back when already paused.
    public var snoozeChoices: [SnoozeChoice] {
        isSnoozed ? [.wake, .hour, .tomorrow, .untilChange] : [.hour, .tomorrow, .untilChange]
    }

    /// Collapses whitespace so a multi-line question or command fits a row.

    /// The last paragraph of a text on one line, without Markdown's marks. Nil when there is none.
    public static func lastLine(of text: String) -> String? {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let last = paragraphs.last else { return nil }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        let plain = (try? AttributedString(markdown: last, options: options)).map { String($0.characters) } ?? last
        let line = singleLine(plain)
        return line.isEmpty ? nil : line
    }

    /// The last paragraphs of a text that fit in `limit` characters: at least the last one, cut
    /// from the front at a word if it is longer on its own.
    public static func ending(of text: String, limit: Int = 360) -> String {
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let last = paragraphs.last else { return "" }
        if last.count > limit {
            let tail = last.suffix(limit)
            let start = tail.firstIndex(of: " ").map { tail.index(after: $0) } ?? tail.startIndex
            return "…" + tail[start...]
        }
        var kept = [last]
        var length = last.count
        for paragraph in paragraphs.dropLast().reversed() {
            guard length + paragraph.count + 2 <= limit else { break }
            kept.insert(paragraph, at: 0)
            length += paragraph.count + 2
        }
        return (kept.count < paragraphs.count ? "… " : "") + kept.joined(separator: "\n\n")
    }

    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension InboxGroups {
    /// The groups as titled sections of rows, leaving out empty ones.
    ///
    /// Pinned sessions come first in a section of their own, whatever their state, and appear in
    /// no other: they are the ones the user keeps, not ones to work through.
    /// - Parameter pinned: every pinned session, including finished ones that the groups leave
    ///   out once they are no longer recent.
    public func sections(
        now: Date = Date(), snoozes: [String: Snooze] = [:], overdueAfter: TimeInterval = MenuBarStatus.defaultOverdueAfter,
        transientErrors: TransientErrors = TransientErrors(), pins: Pins = Pins(), pinned: [Session] = []
    ) -> [(title: String, rows: [InboxRow])] {
        func row(_ session: Session) -> InboxRow {
            InboxRow(
                session: session, snooze: snoozes[session.id], pin: pins.sessions[session.id], overdueAfter: overdueAfter,
                transientErrors: transientErrors, now: now)
        }
        let kept = pinned.filter { pins.isPinned($0.id) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let rest = [("Needs you", needsYou), ("Working", working), ("Recently done", recentlyDone), ("Other", other)]
            .map { ($0.0, $0.1.filter { !pins.isPinned($0.id) }) }
        return ([("Pinned", kept)] + rest)
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, rows: $0.1.map(row)) }
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
    /// So are sessions pinned as quiet: waiting is their normal state.
    public init(
        snapshot: StoreSnapshot, snoozes: [String: Snooze] = [:], quiet: Set<String> = [],
        overdueAfter: TimeInterval = MenuBarStatus.defaultOverdueAfter, now: Date = Date()
    ) {
        let waiting = snapshot.sessions.filter { session in
            session.needsHuman && !quiet.contains(session.id)
                && !(snoozes[session.id]?.isActive(waitingSince: session.waitingSince, now: now) ?? false)
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
