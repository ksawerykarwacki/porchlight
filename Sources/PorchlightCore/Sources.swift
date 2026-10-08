import Foundation

public enum AgentsCLIError: Error, Sendable, Equatable {
    case failed(exitCode: Int32, stderr: String)
    case invalidJSON
}

public struct AgentsSnapshot: Sendable, Equatable {
    public let sessions: [SessionSummary]
    /// Rows that could not be decoded at all (for example, no `id`).
    public let skipped: Int
}

/// The official source: `claude agents --json --all`.
public struct AgentsCLISource: Sendable {
    public let executable: URL
    public let runner: CLIRunner

    public init(executable: URL, runner: CLIRunner = CLIRunner()) {
        self.executable = executable
        self.runner = runner
    }

    public func snapshot(includeCompleted: Bool = true) async throws -> AgentsSnapshot {
        var arguments = ["agents", "--json"]
        if includeCompleted { arguments.append("--all") }
        let result = try await runner.run(executable, arguments)
        guard result.succeeded else {
            throw AgentsCLIError.failed(exitCode: result.exitCode, stderr: ANSI.strip(result.stderr))
        }
        return try Self.decode(result.stdout)
    }

    static func decode(_ json: String) throws -> AgentsSnapshot {
        guard let rows = try? JSONDecoder().decode(LossyArray<SessionSummary>.self, from: Data(json.utf8)) else {
            throw AgentsCLIError.invalidJSON
        }
        return AgentsSnapshot(sessions: rows.elements, skipped: rows.skipped)
    }
}

/// Optional enrichment from Claude Code's internal job files. Never writes; a missing or
/// unrecognised file just means no enrichment for that session.
public struct JobStateSource: Sendable {
    public let jobsDirectory: URL

    public init(jobsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/jobs")) {
        self.jobsDirectory = jobsDirectory
    }

    public func load(id: String) -> JobState? {
        // Session ids are short hex strings; refuse anything that could leave the jobs directory.
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        let url = jobsDirectory.appendingPathComponent(id).appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JobState.self, from: data)
    }

    public func enrich(_ summaries: [SessionSummary]) -> [Session] {
        summaries.map { Session(summary: $0, job: load(id: $0.id)) }
    }
}
