import Foundation

/// Splits a session's working directory into the repository and, if any, its Claude worktree.
public struct RepoLocation: Sendable, Equatable {
    public let repoRoot: String
    public let worktreeName: String?

    private static let marker = "/.claude/worktrees/"

    /// The CLI reports the worktree path as `cwd` once a session has moved into one.
    public init(cwd: String) {
        if let range = cwd.range(of: Self.marker) {
            repoRoot = String(cwd[..<range.lowerBound])
            let rest = cwd[range.upperBound...]
            worktreeName = rest.split(separator: "/").first.map(String.init)
        } else {
            repoRoot = cwd
            worktreeName = nil
        }
    }

    public var repoName: String {
        repoRoot.split(separator: "/").last.map(String.init) ?? repoRoot
    }
}

/// A session as shown to the user: the official summary plus optional internal enrichment.
public struct Session: Sendable, Equatable, Identifiable {
    public let summary: SessionSummary
    public let job: JobState?
    /// When the store first saw this session blocked. Filled in by `SessionStore`.
    public var observedBlockedSince: Date?
    /// What the companion mod reported about this session, when it has the mod. Filled in by
    /// `SessionStore`.
    public var companion: CompanionFacts?

    public init(summary: SessionSummary, job: JobState? = nil, observedBlockedSince: Date? = nil, companion: CompanionFacts? = nil) {
        self.summary = summary
        self.job = job
        self.observedBlockedSince = observedBlockedSince
        self.companion = companion
    }

    /// How much later than the mod's report the job file may be written and still be about the
    /// same wait. The mod is told as the question is asked; Claude Code writes its file a moment
    /// after. A file later than this is about something the mod did not report.
    static let reportLead: TimeInterval = 5

    /// What the mod says the session is waiting on. Where the mod is present this is used in
    /// place of the job file, which Claude Code calls "not a stable interface"; the file is the
    /// fallback when the mod is absent, silent, or clearly behind.
    private var reportedWaiting: CompanionFacts.Waiting? {
        guard needsHuman, let companion, let waiting = companion.waiting else { return nil }
        if let written = job?.updatedAt, let since = companion.waitingSince, written.timeIntervalSince(since) > Self.reportLead { return nil }
        return waiting
    }

    public var id: String { summary.id }
    public var name: String { summary.name.isEmpty ? (job?.name ?? summary.id) : summary.name }
    public var location: RepoLocation { RepoLocation(cwd: summary.cwd) }
    public var needsHuman: Bool { summary.state == .blocked }

    /// What the session is waiting on. Only meaningful while blocked: the job file keeps the last
    /// `needs` around after the session moves on.
    public var needs: Needs? {
        switch reportedWaiting {
        case .question(let questions)?: return questions.first.map { .question($0.question) } ?? (needsHuman ? job?.needs : nil)
        case .permission(let tool, let detail)?: return .approval(tool: tool, detail: detail)
        case nil: return needsHuman ? job?.needs : nil
        }
    }

    public var questions: [JobState.Question] {
        if case .question(let questions)? = reportedWaiting { return questions }
        return needsHuman ? (job?.questions ?? []) : []
    }
    public var suggestedReply: String? { needsHuman ? job?.suggestedReply : nil }

    /// When the session started waiting: the job file's last update if there is one, otherwise the
    /// first time the store observed it blocked.
    public var waitingSince: Date? { needsHuman ? (job?.updatedAt ?? observedBlockedSince) : nil }

    /// The most recent moment anything is known to have happened in the session.
    public var lastActivity: Date? { job?.updatedAt ?? summary.startedAt }
}

/// The inbox's three groups, in display order.
public struct InboxGroups: Sendable, Equatable {
    /// Blocked sessions, longest wait first; sessions with an unknown wait go last.
    public let needsYou: [Session]
    /// Working sessions, longest running first.
    public let working: [Session]
    /// Finished sessions whose last activity falls inside the window, most recent first.
    public let recentlyDone: [Session]
    /// Sessions in a state this version does not know. Shown neutrally, never dropped.
    public let other: [Session]

    public static let defaultRecentWindow: TimeInterval = 24 * 3600

    public init(sessions: [Session], now: Date = Date(), recentWindow: TimeInterval = InboxGroups.defaultRecentWindow) {
        func oldestFirst(_ key: @escaping (Session) -> Date?) -> (Session, Session) -> Bool {
            { left, right in
                switch (key(left), key(right)) {
                case let (l?, r?) where l != r: l < r
                case (_?, nil): true
                case (nil, _?): false
                default: left.name.localizedStandardCompare(right.name) == .orderedAscending
                }
            }
        }
        needsYou = sessions.filter { $0.summary.state == .blocked }.sorted(by: oldestFirst(\.waitingSince))
        working = sessions.filter { $0.summary.state == .working }.sorted(by: oldestFirst { $0.summary.startedAt })
        recentlyDone = sessions
            .filter { session in
                guard session.summary.state == .done else { return false }
                guard let last = session.lastActivity else { return true }
                return now.timeIntervalSince(last) <= recentWindow
            }
            .sorted(by: oldestFirst(\.lastActivity))
            .reversed()
        other = sessions.filter { if case .unknown = $0.summary.state { true } else { false } }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public var isEmpty: Bool { needsYou.isEmpty && working.isEmpty && recentlyDone.isEmpty && other.isEmpty }
}

/// Compact ages for rows: "just now", "12m", "3h", "5d".
public enum Age {
    public static func short(since date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }
}
