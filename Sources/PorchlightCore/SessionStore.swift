import Foundation

/// Why the store's snapshot is not fresh.
public enum StoreProblem: Sendable, Equatable {
    case claudeNotFound(candidates: [String])
    case cliFailed(exitCode: Int32, stderr: String)
    case invalidOutput
    case timedOut
    case other(String)

    init(_ error: Error) {
        switch error {
        case let problem as StoreProblem: self = problem
        case AgentsCLIError.failed(let exitCode, let stderr): self = .cliFailed(exitCode: exitCode, stderr: stderr)
        case AgentsCLIError.invalidJSON: self = .invalidOutput
        case CLIError.timedOut: self = .timedOut
        default: self = .other(String(describing: error))
        }
    }
}

extension StoreProblem: Error {}

public struct StoreSnapshot: Sendable, Equatable {
    /// The sessions from the last successful read. Kept across failed reads.
    public var sessions: [Session] = []
    public var skippedRows = 0
    /// When `sessions` was last read successfully; nil before the first success.
    public var fetchedAt: Date?
    /// Set when the latest read failed, which makes `sessions` stale.
    public var problem: StoreProblem?

    public var isStale: Bool { problem != nil }
    public var waitingCount: Int { sessions.filter(\.needsHuman).count }

    public init() {}
}

public enum SessionEvent: Sendable, Equatable {
    case appeared(Session)
    case becameBlocked(Session)
    case unblocked(Session)
    /// Anything else changed: state, the question, the name.
    case changed(Session)
    case removed(id: String)
}

public struct StoreUpdate: Sendable, Equatable {
    public let snapshot: StoreSnapshot
    public let events: [SessionEvent]
}

/// The single place that knows the current sessions. Merges the CLI with job-file enrichment,
/// survives failed reads, and remembers when each session started waiting.
public actor SessionStore {
    public typealias Fetch = @Sendable () async throws -> AgentsSnapshot
    public typealias Enrich = @Sendable ([SessionSummary]) -> [Session]

    private let fetch: Fetch
    private let enrich: Enrich
    private let now: @Sendable () -> Date
    private let blockedSinceFile: URL?
    private var blockedSince: [String: Date]
    private var isRefreshing = false
    private var refreshRequestedWhileBusy = false
    private var observers: [UUID: AsyncStream<StoreUpdate>.Continuation] = [:]

    public private(set) var snapshot = StoreSnapshot()

    /// - Parameter blockedSinceFile: where first-observed-blocked times are kept so a restart does
    ///   not reset the wait clock. Nil keeps them in memory only.
    public init(
        fetch: @escaping Fetch,
        enrich: @escaping Enrich = { $0.map { Session(summary: $0) } },
        blockedSinceFile: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fetch = fetch
        self.enrich = enrich
        self.now = now
        self.blockedSinceFile = blockedSinceFile
        self.blockedSince = blockedSinceFile.flatMap(Self.load) ?? [:]
    }

    /// The store used by the app and the command-line tool: real CLI, real job files.
    public static func live(
        locator: ClaudeLocator = ClaudeLocator(),
        jobs: JobStateSource = JobStateSource(),
        stateDirectory: URL = PorchlightPaths.stateDirectory()
    ) -> SessionStore {
        SessionStore(
            fetch: {
                // Located on every read, so installing claude later recovers without a restart.
                guard let claude = locator.locate() else {
                    throw StoreProblem.claudeNotFound(candidates: locator.candidates())
                }
                return try await AgentsCLISource(executable: claude).snapshot()
            },
            enrich: { jobs.enrich($0) },
            blockedSinceFile: stateDirectory.appendingPathComponent("blocked-since.json")
        )
    }

    /// Reads the sessions. Two reads never run at once: a call that arrives while one is running
    /// returns no events straight away and makes the running call read once more when it is done,
    /// so a change that lands mid-read is not missed and slow reads never pile up.
    @discardableResult
    public func refresh() async -> [SessionEvent] {
        guard !isRefreshing else {
            refreshRequestedWhileBusy = true
            return []
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var allEvents: [SessionEvent] = []
        repeat {
            refreshRequestedWhileBusy = false
            allEvents += await readOnce()
        } while refreshRequestedWhileBusy
        return allEvents
    }

    private func readOnce() async -> [SessionEvent] {
        let result: Result<AgentsSnapshot, Error>
        do {
            result = .success(try await fetch())
        } catch {
            result = .failure(error)
        }

        var events: [SessionEvent] = []
        switch result {
        case .success(let agents):
            let previous = snapshot.sessions
            let timestamp = now()
            var sessions = enrich(agents.sessions)
            recordBlocked(in: &sessions, at: timestamp)
            snapshot.sessions = sessions
            snapshot.skippedRows = agents.skipped
            snapshot.fetchedAt = timestamp
            snapshot.problem = nil
            events = Self.diff(from: previous, to: sessions)
        case .failure(let error):
            snapshot.problem = StoreProblem(error)
        }

        let update = StoreUpdate(snapshot: snapshot, events: events)
        for observer in observers.values { observer.yield(update) }
        return events
    }

    /// Every refresh from now on, whether or not anything changed.
    public func updates() -> AsyncStream<StoreUpdate> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<StoreUpdate>.makeStream(bufferingPolicy: .bufferingNewest(16))
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    private func recordBlocked(in sessions: inout [Session], at timestamp: Date) {
        var updated: [String: Date] = [:]
        for index in sessions.indices where sessions[index].needsHuman {
            let id = sessions[index].id
            let since = blockedSince[id] ?? timestamp
            updated[id] = since
            sessions[index].observedBlockedSince = since
        }
        guard updated != blockedSince else { return }
        blockedSince = updated
        if let blockedSinceFile { Self.save(updated, to: blockedSinceFile) }
    }

    static func diff(from old: [Session], to new: [Session]) -> [SessionEvent] {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var events: [SessionEvent] = []
        for session in new {
            guard let previous = before[session.id] else {
                events.append(.appeared(session))
                if session.needsHuman { events.append(.becameBlocked(session)) }
                continue
            }
            if session.needsHuman && !previous.needsHuman {
                events.append(.becameBlocked(session))
            } else if !session.needsHuman && previous.needsHuman {
                events.append(.unblocked(session))
            } else if session != previous {
                events.append(.changed(session))
            }
        }
        let current = Set(new.map(\.id))
        for session in old where !current.contains(session.id) {
            events.append(.removed(id: session.id))
        }
        return events
    }

    private static func load(_ url: URL) -> [String: Date]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode([String: Date].self, from: data)
    }

    private static func save(_ times: [String: Date], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(times) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

public enum PorchlightPaths {
    /// Where Porchlight keeps its own state: `~/Library/Application Support/Porchlight` on macOS.
    public static func stateDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".porchlight")
        return base.appendingPathComponent("Porchlight", isDirectory: true)
    }
}
