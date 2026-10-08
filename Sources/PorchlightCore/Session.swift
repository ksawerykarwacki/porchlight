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

    public init(summary: SessionSummary, job: JobState? = nil) {
        self.summary = summary
        self.job = job
    }

    public var id: String { summary.id }
    public var name: String { summary.name.isEmpty ? (job?.name ?? summary.id) : summary.name }
    public var location: RepoLocation { RepoLocation(cwd: summary.cwd) }
    public var needsHuman: Bool { summary.state == .blocked }

    /// What the session is waiting on. Only meaningful while blocked: the job file keeps the last
    /// `needs` around after the session moves on.
    public var needs: Needs? { needsHuman ? job?.needs : nil }
    public var questions: [JobState.Question] { needsHuman ? (job?.questions ?? []) : [] }
    public var suggestedReply: String? { needsHuman ? job?.suggestedReply : nil }

    /// When the session started waiting, if known. Without enrichment the store has to track the
    /// first time it observed `blocked` itself.
    public var waitingSince: Date? { needsHuman ? job?.updatedAt : nil }
}
