import Foundation

/// Something that says "the sessions may have changed, read them again". A trigger never carries
/// data: the CLI stays the source of truth.
public protocol ChangeTrigger: Sendable {
    func changes() -> AsyncStream<Void>
}

/// Portable watcher for a jobs directory: compares a cheap fingerprint of the per-session state
/// files at a short interval. Platform frontends can supply a notification-based trigger instead.
public struct PollingChangeWatcher: ChangeTrigger {
    public let directory: URL
    public let interval: Duration

    public init(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/jobs"),
        interval: Duration = .seconds(1)
    ) {
        self.directory = directory
        self.interval = interval
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var last = Self.fingerprint(of: directory)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let current = Self.fingerprint(of: directory)
                if current != last {
                    last = current
                    continuation.yield()
                }
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// One line per job directory: its name and its state file's size and modification time.
    /// A missing directory or a job without a state file is not an error.
    static func fingerprint(of directory: URL) -> [String] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { return [] }
        return entries.sorted().map { entry in
            let state = directory.appendingPathComponent(entry).appendingPathComponent("state.json").path
            guard let attributes = try? manager.attributesOfItem(atPath: state) else { return entry }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return "\(entry) \(size) \(modified)"
        }
    }
}

/// Keeps a store fresh: reads on a timer, and sooner whenever a trigger fires.
public struct RefreshLoop: Sendable {
    /// Timer interval while something is working or waiting.
    public var activeInterval: Duration
    /// Timer interval while every session is finished.
    public var idleInterval: Duration
    /// Wait after a trigger before reading, so a burst of file writes costs one read.
    public var debounce: Duration

    public init(activeInterval: Duration = .seconds(10), idleInterval: Duration = .seconds(60), debounce: Duration = .milliseconds(200)) {
        self.activeInterval = activeInterval
        self.idleInterval = idleInterval
        self.debounce = debounce
    }

    public func interval(for snapshot: StoreSnapshot) -> Duration {
        // A stale snapshot is retried at the active pace: the last known state may be out of date.
        let active = snapshot.isStale || snapshot.sessions.contains { $0.summary.state == .blocked || $0.summary.state == .working }
        return active ? activeInterval : idleInterval
    }

    /// Runs until the surrounding task is cancelled.
    public func run(store: SessionStore, triggers: [any ChangeTrigger] = []) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                while !Task.isCancelled {
                    await store.refresh()
                    try? await Task.sleep(for: interval(for: await store.snapshot))
                }
            }
            for trigger in triggers {
                group.addTask {
                    for await _ in trigger.changes() {
                        try? await Task.sleep(for: debounce)
                        if Task.isCancelled { break }
                        await store.refresh()
                    }
                }
            }
        }
    }
}

/// One line of `porchlight watch`: the full status plus what changed to produce it.
public struct WatchLine: Sendable, Encodable {
    public struct Change: Sendable, Encodable {
        /// "appeared", "becameBlocked", "unblocked", "changed" or "removed".
        public let kind: String
        public let id: String
    }

    /// "snapshot" for the first line, "update" for every later one.
    public let event: String
    public let changes: [Change]
    public let stale: Bool
    public let status: StatusReport

    public init(update: StoreUpdate, isFirst: Bool, generatedAt: Date = Date()) {
        event = isFirst ? "snapshot" : "update"
        stale = update.snapshot.isStale
        status = StatusReport(sessions: update.snapshot.sessions, skippedRows: update.snapshot.skippedRows, generatedAt: generatedAt)
        changes = update.events.map { event in
            switch event {
            case .appeared(let session): Change(kind: "appeared", id: session.id)
            case .becameBlocked(let session): Change(kind: "becameBlocked", id: session.id)
            case .unblocked(let session): Change(kind: "unblocked", id: session.id)
            case .changed(let session): Change(kind: "changed", id: session.id)
            case .removed(let id): Change(kind: "removed", id: id)
            }
        }
    }

    /// A single line of JSON, safe to split a stream on newlines.
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
