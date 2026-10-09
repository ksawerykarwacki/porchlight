import Foundation

/// What is known about the pull request for a session's branch.
public enum PullRequestState: Sendable, Equatable {
    case open(number: Int)
    case merged(number: Int)
    case closed(number: Int)
    /// Looked for and not found.
    case none
    /// Could not be looked up: no `gh`, not signed in, not a GitHub repository, no network.
    case unknown

    public var summary: String {
        switch self {
        case .open(let number): "PR #\(number) is open"
        case .merged(let number): "PR #\(number) is merged"
        case .closed(let number): "PR #\(number) was closed without merging"
        case .none: "no pull request"
        case .unknown: "pull request could not be checked"
        }
    }
}

/// Finds the pull request of a branch with the GitHub CLI. Other hosts can be added behind the
/// same closure later.
public struct PullRequestLookup: Sendable {
    public var gh: URL?
    public var runner: CLIRunner
    public var environment: [String: String]?

    public init(gh: URL? = PullRequestLookup.locateGH(), runner: CLIRunner = CLIRunner(), environment: [String: String]? = nil) {
        self.gh = gh
        self.runner = runner
        self.environment = environment
    }

    /// `PORCHLIGHT_GH` overrides where `gh` is; a GUI app does not get the shell's PATH.
    public static func locateGH(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        let candidates = [environment["PORCHLIGHT_GH"]].compactMap { $0 } + ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        return candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }

    public static func arguments(branch: String) -> [String] {
        ["pr", "list", "--head", branch, "--state", "all", "--limit", "1", "--json", "number,state"]
    }

    /// The most recent pull request whose head is `branch`, in the repository at `directory`.
    public func state(branch: String, in directory: String) async -> PullRequestState {
        // A branch name that could be read as a flag is not passed on.
        guard let gh, !branch.isEmpty, !branch.hasPrefix("-"), RepoIndex.directoryExists(directory) else { return .unknown }
        guard let result = try? await runner.run(
            gh, Self.arguments(branch: branch), cwd: URL(fileURLWithPath: directory, isDirectory: true), environment: environment, timeout: 20),
            result.succeeded
        else { return .unknown }
        return Self.parse(result.stdout)
    }

    struct Row: Decodable {
        let number: Int
        let state: String
    }

    /// `gh pr list --json number,state` prints an array; empty means there is none.
    public static func parse(_ output: String) -> PullRequestState {
        guard let rows = try? JSONDecoder().decode([Row].self, from: Data(output.utf8)) else { return .unknown }
        guard let row = rows.first else { return .none }
        switch row.state.uppercased() {
        case "OPEN": return .open(number: row.number)
        case "MERGED": return .merged(number: row.number)
        case "CLOSED": return .closed(number: row.number)
        default: return .unknown
        }
    }
}

/// When a session counts as stale, and how young a finished one is left alone.
public struct TriageSettings: Codable, Sendable, Equatable {
    public static let defaultStaleAfter: TimeInterval = 7 * 86400
    public static let defaultMinimumAge: TimeInterval = 86400

    /// A session waiting or stopped for longer than this is stale.
    public var staleAfter: TimeInterval
    /// A session that finished less than this long ago is kept out of triage: it may still be
    /// about to be looked at.
    public var minimumAge: TimeInterval

    public init(staleAfter: TimeInterval = TriageSettings.defaultStaleAfter, minimumAge: TimeInterval = TriageSettings.defaultMinimumAge) {
        self.staleAfter = staleAfter
        self.minimumAge = minimumAge
    }

    private enum CodingKeys: String, CodingKey {
        case staleAfter, minimumAge
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let stale = (try? c.decodeIfPresent(TimeInterval.self, forKey: .staleAfter)) ?? Self.defaultStaleAfter
        let minimum = (try? c.decodeIfPresent(TimeInterval.self, forKey: .minimumAge)) ?? Self.defaultMinimumAge
        staleAfter = stale >= 3600 ? stale : Self.defaultStaleAfter
        minimumAge = minimum >= 0 ? minimum : Self.defaultMinimumAge
    }
}

/// What to do with a session that is no longer moving.
public enum TriageVerdict: String, Sendable, Equatable, CaseIterable {
    /// Removing it loses nothing.
    case safeToRemove
    /// It holds work that exists nowhere else, or that could not be checked.
    case needsDecision
    /// It has been waiting or stopped for a long time.
    case stale
    /// Still in use: an open pull request.
    case keep

    public var title: String {
        switch self {
        case .safeToRemove: "Safe to remove"
        case .needsDecision: "Needs a decision"
        case .stale: "Stale"
        case .keep: "Keep"
        }
    }

    public var explanation: String {
        switch self {
        case .safeToRemove: "Finished, with nothing that would be lost."
        case .needsDecision: "Holds work that is saved nowhere else, or that could not be checked."
        case .stale: "Waiting or stopped for a long time."
        case .keep: "Still in use."
        }
    }
}

/// Everything gathered about one session for triage.
public struct TriageFacts: Sendable, Equatable {
    public var session: Session
    /// The session's Claude worktree, when it has one that is still on disk.
    public var worktree: WorktreeReport?
    /// True when the session has a worktree (its job details name one) but it could not be read.
    public var worktreeUnreadable: Bool
    public var pullRequest: PullRequestState
    /// The branch the pull request was looked up for.
    public var branch: String?

    public init(session: Session, worktree: WorktreeReport? = nil, worktreeUnreadable: Bool = false, pullRequest: PullRequestState = .none, branch: String? = nil) {
        self.session = session
        self.worktree = worktree
        self.worktreeUnreadable = worktreeUnreadable
        self.pullRequest = pullRequest
        self.branch = branch
    }
}

/// A session with its verdict and the reasons for it, for a list.
public struct TriageItem: Sendable, Equatable, Identifiable {
    public let facts: TriageFacts
    public let verdict: TriageVerdict
    /// Why, in a line: the facts the verdict rests on.
    public let reason: String

    public var id: String { facts.session.id }
    public var session: Session { facts.session }
}

public enum Triage {
    /// Whether a session belongs in triage at all. Pinned sessions are kept on purpose, working
    /// ones are in use, a session in a terminal of its own cannot be removed from here, and a
    /// recently finished or recently blocked one is not yet something to clear.
    public static func isCandidate(_ session: Session, pins: Pins, settings: TriageSettings, now: Date) -> Bool {
        guard !pins.isPinned(session.id), SessionAction.remove.applies(to: session) else { return false }
        let idle = now.timeIntervalSince(session.lastActivity ?? .distantPast)
        switch session.summary.state {
        case .working: return false
        case .blocked: return now.timeIntervalSince(session.waitingSince ?? session.lastActivity ?? now) >= settings.staleAfter
        case .done, .unknown: return idle >= settings.minimumAge
        }
    }

    public static func verdict(for facts: TriageFacts, settings: TriageSettings = TriageSettings(), now: Date = Date()) -> TriageItem {
        var reasons: [String] = []
        if let worktree = facts.worktree {
            if worktree.uncommitted > 0 { reasons.append("\(worktree.uncommitted) uncommitted \(worktree.uncommitted == 1 ? "file" : "files")") }
            if let unpushed = worktree.unpushed, unpushed > 0 { reasons.append("\(unpushed) \(unpushed == 1 ? "commit" : "commits") on no remote") }
        }
        // Work that exists nowhere else comes first: whatever else is true, removing would lose it.
        if !reasons.isEmpty {
            // A merged pull request is worth saying here: the commits may be "on no remote" only
            // because the branch was deleted after the merge, which is for the user to judge.
            if case .merged = facts.pullRequest { reasons.append(facts.pullRequest.summary) }
            return TriageItem(facts: facts, verdict: .needsDecision, reason: reasons.joined(separator: ", "))
        }
        if facts.worktreeUnreadable || (facts.worktree != nil && facts.worktree?.unpushed == nil) {
            return TriageItem(facts: facts, verdict: .needsDecision, reason: "its worktree could not be checked")
        }
        if case .open = facts.pullRequest {
            return TriageItem(facts: facts, verdict: .keep, reason: facts.pullRequest.summary)
        }
        let session = facts.session
        if session.summary.state == .blocked {
            let waited = Age.short(since: session.waitingSince ?? session.lastActivity, now: now) ?? "a long time"
            return TriageItem(facts: facts, verdict: .stale, reason: "waiting for \(waited)")
        }
        var basis = [facts.worktree == nil ? "no worktree" : "worktree clean"]
        // "Could not check" is said, and does not block: nothing local would be lost either way.
        if facts.branch != nil || facts.pullRequest != .none { basis.append(facts.pullRequest.summary) }
        if case .unknown(let raw) = session.summary.state, now.timeIntervalSince(session.lastActivity ?? .distantPast) >= settings.staleAfter {
            return TriageItem(facts: facts, verdict: .stale, reason: (["\(raw) for a long time"] + basis).joined(separator: ", "))
        }
        return TriageItem(facts: facts, verdict: .safeToRemove, reason: basis.joined(separator: ", "))
    }

    /// The order of the list: what can go first, then what needs thought, each by name.
    public static func sorted(_ items: [TriageItem]) -> [TriageItem] {
        let order: [TriageVerdict] = [.safeToRemove, .needsDecision, .stale, .keep]
        return items.sorted { a, b in
            let (ia, ib) = (order.firstIndex(of: a.verdict) ?? 0, order.firstIndex(of: b.verdict) ?? 0)
            return ia != ib ? ia < ib : a.session.name.localizedCaseInsensitiveCompare(b.session.name) == .orderedAscending
        }
    }
}

/// Gathers the facts for every session that belongs in triage. Reads the disk and asks `gh`, so
/// it is slow; both are passed in.
public struct TriageGatherer: Sendable {
    public var inspectWorktree: @Sendable (Session) async -> WorktreeReport?
    public var pullRequest: @Sendable (_ branch: String, _ directory: String) async -> PullRequestState
    public var branchOf: @Sendable (String) -> String?

    public init(
        inspectWorktree: @escaping @Sendable (Session) async -> WorktreeReport? = { await WorktreeInspector().report(for: $0) },
        pullRequest: @escaping @Sendable (String, String) async -> PullRequestState = { await PullRequestLookup().state(branch: $0, in: $1) },
        branchOf: @escaping @Sendable (String) -> String? = { GitBranch.current(in: $0) }
    ) {
        self.inspectWorktree = inspectWorktree
        self.pullRequest = pullRequest
        self.branchOf = branchOf
    }

    public func facts(for session: Session) async -> TriageFacts {
        let report = await inspectWorktree(session)
        let namedWorktree = session.job?.worktreePath.flatMap { $0.isEmpty ? nil : $0 } ?? (session.location.worktreeName != nil ? session.summary.cwd : nil)
        // A worktree the session names that is gone from disk was already cleaned up: nothing to
        // lose. One that is there and cannot be read is unknown, which is never "safe".
        let unreadable = report == nil && namedWorktree.map(RepoIndex.directoryExists) == true
        let branch = session.job?.worktreeBranch.flatMap { $0.isEmpty ? nil : $0 } ?? report.flatMap { branchOf($0.path) }
        var state = PullRequestState.none
        if let branch {
            state = await pullRequest(branch, session.location.repoRoot)
        }
        return TriageFacts(session: session, worktree: report, worktreeUnreadable: unreadable, pullRequest: state, branch: branch)
    }

    public func items(sessions: [Session], pins: Pins, settings: TriageSettings = TriageSettings(), now: Date = Date()) async -> [TriageItem] {
        let candidates = sessions.filter { Triage.isCandidate($0, pins: pins, settings: settings, now: now) }
        var items: [TriageItem] = []
        await withTaskGroup(of: TriageItem.self) { group in
            for session in candidates {
                group.addTask { Triage.verdict(for: await facts(for: session), settings: settings, now: now) }
            }
            for await item in group { items.append(item) }
        }
        return Triage.sorted(items)
    }
}
