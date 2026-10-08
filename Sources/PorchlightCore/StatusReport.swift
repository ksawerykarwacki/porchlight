import Foundation

/// The JSON contract of `porchlight status --json`: what any other frontend builds on.
public struct StatusReport: Sendable, Encodable {
    public struct Row: Sendable, Encodable {
        public struct NeedsReport: Sendable, Encodable {
            /// "question", "approval" or "other".
            public let kind: String
            public let text: String
            public let tool: String?
        }

        public struct OptionReport: Sendable, Encodable {
            public let label: String
            public let description: String?
        }

        public let id: String
        public let name: String
        public let repo: String
        public let worktree: String?
        public let cwd: String
        public let state: String
        public let status: String?
        public let waitingFor: String?
        public let needs: NeedsReport?
        public let options: [OptionReport]
        public let suggestedReply: String?
        public let waitingSince: Date?
        public let enriched: Bool
    }

    public let schemaVersion = 1
    public let generatedAt: Date
    public let waiting: Int
    public let skippedRows: Int
    public let sessions: [Row]

    public init(sessions: [Session], skippedRows: Int = 0, generatedAt: Date = Date()) {
        self.generatedAt = generatedAt
        self.skippedRows = skippedRows
        self.waiting = sessions.filter(\.needsHuman).count
        self.sessions = sessions.map(Row.init(session:))
    }

    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

extension StatusReport.Row {
    init(session: Session) {
        let location = session.location
        id = session.id
        name = session.name
        repo = location.repoName
        worktree = location.worktreeName
        cwd = session.summary.cwd
        state = session.summary.state.rawValue
        status = session.summary.status
        waitingFor = session.summary.waitingFor
        needs = session.needs.map { needs in
            switch needs {
            case .question(let text): .init(kind: "question", text: text, tool: nil)
            case .approval(let tool, let detail): .init(kind: "approval", text: detail, tool: tool)
            case .other(let text): .init(kind: "other", text: text, tool: nil)
            }
        }
        // Options of the first question only: one question per block is all that has been observed.
        options = (session.questions.first?.options ?? []).map { .init(label: $0.label, description: $0.description) }
        suggestedReply = session.suggestedReply
        waitingSince = session.waitingSince
        enriched = session.job != nil
    }
}
