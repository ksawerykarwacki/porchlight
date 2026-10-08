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
    /// "repo" or "repo · worktree".
    public let place: String
    /// "waiting 3h" for blocked sessions, otherwise how long ago anything happened.
    public let age: String?
    public let kind: Kind
    /// The question, the command awaiting approval, or the raw need. Nil when nothing is known.
    public let detail: String?
    /// The tool a pending approval is for, such as "Bash".
    public let tool: String?
    /// Choices offered with a question, in order.
    public let options: [String]
    public let suggestedReply: String?

    public init(session: Session, now: Date = Date()) {
        id = session.id
        title = session.name
        let location = session.location
        place = location.worktreeName.map { "\(location.repoName) · \($0)" } ?? location.repoName

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
            age = Age.short(since: session.waitingSince, now: now).map { "waiting \($0)" }
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
        options = session.questions.first?.options.map(\.label) ?? []
        suggestedReply = session.suggestedReply
    }

    /// Collapses whitespace so a multi-line question or command fits a row.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension InboxGroups {
    /// The groups as titled sections of rows, leaving out empty ones.
    public func sections(now: Date = Date()) -> [(title: String, rows: [InboxRow])] {
        [("Needs you", needsYou), ("Working", working), ("Recently done", recentlyDone), ("Other", other)]
            .filter { !$0.1.isEmpty }
            .map { (title: $0.0, rows: $0.1.map { InboxRow(session: $0, now: now) }) }
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
