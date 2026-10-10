import Foundation

/// What a blocked session is waiting on, parsed from the internal `needs` string.
public enum Needs: Sendable, Equatable {
    /// "answer: <question> (<option> · <option>)"
    case question(String)
    /// "approve <Tool>: <command>"
    case approval(tool: String, detail: String)
    /// Anything without a recognised prefix; shown as is.
    case other(String)

    public init(parsing raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rest = text.dropPrefix("answer:") {
            self = .question(rest)
        } else if let rest = text.dropPrefix("approve "), let colon = rest.firstIndex(of: ":") {
            let tool = rest[..<colon].trimmingCharacters(in: .whitespaces)
            let detail = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            self = .approval(tool: tool, detail: detail)
        } else {
            self = .other(text)
        }
    }

    public var text: String {
        switch self {
        case .question(let text), .other(let text): text
        case .approval(_, let detail): detail
        }
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

/// Unofficial per-session state from `~/.claude/jobs/<id>/state.json`. Read-only enrichment: the
/// CLI stays the source of truth, and this schema can change without notice.
///
/// `intent` and `providerEnv` are deliberately not decoded: they can hold pasted secrets and
/// environment values.
public struct JobState: Sendable, Equatable, Decodable {
    public struct Question: Sendable, Equatable, Decodable {
        public struct Option: Sendable, Equatable, Decodable {
            public let label: String
            public let description: String?
        }

        public let question: String
        public let options: [Option]
        /// True when several options may be chosen at once.
        public let multiSelect: Bool

        private enum CodingKeys: String, CodingKey { case question, options, multiSelect }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            question = try c.decode(String.self, forKey: .question)
            options = (try? c.decodeIfPresent(LossyArray<Option>.self, forKey: .options))?.elements ?? []
            multiSelect = (try? c.decodeIfPresent(Bool.self, forKey: .multiSelect)) ?? false
        }
    }

    public struct Child: Sendable, Equatable, Decodable {
        public let id: String?
        public let href: String?
        public let kind: String?
    }

    /// Lags the CLI: observed as "working" while the session was blocked. Use `tempo` or the CLI.
    public let state: String
    public let name: String
    public let nameSource: String?
    public let tempo: String?
    public let needs: Needs?
    public let detail: String?
    public let suggestedReply: String?
    /// The repository root, even when the session works in a worktree.
    public let cwd: String?
    public let worktreePath: String?
    public let worktreeBranch: String?
    public let updatedAt: Date?
    public let createdAt: Date?
    public let questions: [Question]
    public let children: [Child]
    public let cliVersion: String?
    /// Claude Code's own sentence on what the last turn came to. Where the session stands,
    /// beside what it asks for in `needs`.
    public let result: String?

    private enum CodingKeys: String, CodingKey {
        case state, name, nameSource, tempo, needs, detail, suggestedReply, cwd, worktreePath
        case worktreeBranch, updatedAt, createdAt, block, children, cliVersion, output
    }

    private enum BlockKeys: String, CodingKey { case questions }
    private enum OutputKeys: String, CodingKey { case result }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Minimal schema check: without these two strings the file is not what we think it is.
        state = try c.decode(String.self, forKey: .state)
        name = try c.decode(String.self, forKey: .name)

        func string(_ key: CodingKeys) -> String? {
            guard let value = try? c.decodeIfPresent(String.self, forKey: key) else { return nil }
            return value.isEmpty ? nil : value
        }
        nameSource = string(.nameSource)
        tempo = string(.tempo)
        needs = string(.needs).map(Needs.init(parsing:))
        detail = string(.detail)
        suggestedReply = string(.suggestedReply)
        cwd = string(.cwd)
        worktreePath = string(.worktreePath)
        worktreeBranch = string(.worktreeBranch)
        updatedAt = string(.updatedAt).flatMap(Self.parseDate)
        createdAt = string(.createdAt).flatMap(Self.parseDate)
        cliVersion = string(.cliVersion)

        // Sometimes an object, sometimes null; only its one sentence is taken.
        let output = try? c.nestedContainer(keyedBy: OutputKeys.self, forKey: .output)
        let sentence = (try? output?.decodeIfPresent(String.self, forKey: .result)) ?? nil
        result = sentence.flatMap { $0.isEmpty ? nil : $0 }

        let block = try? c.nestedContainer(keyedBy: BlockKeys.self, forKey: .block)
        questions = (try? block?.decodeIfPresent(LossyArray<Question>.self, forKey: .questions))?.elements ?? []
        children = (try? c.decodeIfPresent(LossyArray<Child>.self, forKey: .children))?.elements ?? []
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
