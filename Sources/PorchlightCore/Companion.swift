import Foundation

/// One report from the companion mod running inside a Claude Code session.
///
/// The mod is optional and its interface is early access, so a report only ever adds to what
/// `claude agents` says: it is never the reason a session is listed, and a body that is not what
/// it should be is dropped.
public struct CompanionEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case sessionStart
        case sessionEnd
        case turnStart
        /// `reason` is Claude Code's own word: answer, aborted, refusal or error.
        case turnComplete(reason: String?)
        /// The session asked its user something and is waiting for the answer.
        case question([JobState.Question])
        /// The session wants to run something that needs approval.
        case permission(tool: String, detail: String)
        /// The question was answered or the approval given: it is working again.
        case resumed
        /// A turn ended on an API failure, in Claude Code's own class for it (`rate_limit`,
        /// `overloaded`, `server_error`, …).
        case failure(kind: String)
    }

    /// The conversation's id, as `claude agents` reports it in `sessionId`.
    public let sessionID: String
    public let kind: Kind
    /// When the app received it. The mod's own clock is not asked.
    public let receivedAt: Date

    public init(sessionID: String, kind: Kind, receivedAt: Date) {
        self.sessionID = sessionID
        self.kind = kind
        self.receivedAt = receivedAt
    }

    /// The version of the reports this build understands.
    public static let version = 1
    /// The longest text kept from a report; the rest is cut.
    static let textLimit = 2000

    private struct Body: Decodable {
        let v: Int?
        let session: String?
        let kind: String?
        let reason: String?
        let questions: LossyArray<JobState.Question>?
        let tool: String?
        let detail: String?
        let error: String?
    }

    /// The event in a report's body, or nil when it is not one this build understands: not JSON,
    /// a newer version, no usable session id, or a kind it does not know.
    public static func decode(_ data: Data, receivedAt: Date) -> CompanionEvent? {
        guard let body = try? JSONDecoder().decode(Body.self, from: data), (body.v ?? 1) == version,
              let session = body.session, WrapUp.isValidConversationID(session) else { return nil }
        func cut(_ text: String?) -> String { String((text ?? "").prefix(textLimit)) }
        let kind: Kind
        switch body.kind {
        case "session.start": kind = .sessionStart
        case "session.end": kind = .sessionEnd
        case "turn.start": kind = .turnStart
        case "turn.complete": kind = .turnComplete(reason: body.reason.map { cut($0) })
        case "question":
            let questions = Array((body.questions?.elements ?? []).prefix(8))
            guard !questions.isEmpty else { return nil }
            kind = .question(questions)
        case "permission":
            guard let tool = body.tool, !tool.isEmpty else { return nil }
            kind = .permission(tool: cut(tool), detail: cut(body.detail))
        case "resumed": kind = .resumed
        case "failure":
            guard let error = body.error, !error.isEmpty else { return nil }
            kind = .failure(kind: cut(error))
        default: return nil
        }
        return CompanionEvent(sessionID: session.lowercased(), kind: kind, receivedAt: receivedAt)
    }
}

/// What the mod's reports say about one session right now.
public struct CompanionFacts: Sendable, Equatable {
    public enum Waiting: Sendable, Equatable {
        case question([JobState.Question])
        case permission(tool: String, detail: String)
    }

    /// What the session is waiting on, if the last report says it is waiting.
    public var waiting: Waiting?
    public var waitingSince: Date?
    /// The class of the failure the last turn ended on; cleared when a turn starts.
    public var failure: String?
    public var isTurnRunning = false
    public var lastReportAt: Date

    public init(lastReportAt: Date) {
        self.lastReportAt = lastReportAt
    }

    /// Nil when the event ends the session's facts altogether.
    func applying(_ event: CompanionEvent) -> CompanionFacts? {
        var next = self
        next.lastReportAt = event.receivedAt
        switch event.kind {
        case .sessionStart:
            // A restart or a reload of the mod: whatever was known is no longer.
            return CompanionFacts(lastReportAt: event.receivedAt)
        case .sessionEnd:
            return nil
        case .turnStart:
            next.isTurnRunning = true
            next.waiting = nil
            next.waitingSince = nil
            next.failure = nil
        case .turnComplete:
            next.isTurnRunning = false
            next.waiting = nil
            next.waitingSince = nil
        case .question(let questions):
            next.waiting = .question(questions)
            next.waitingSince = event.receivedAt
        case .permission(let tool, let detail):
            next.waiting = .permission(tool: tool, detail: detail)
            next.waitingSince = event.receivedAt
        case .resumed:
            next.waiting = nil
            next.waitingSince = nil
        case .failure(let kind):
            next.failure = kind
        }
        return next
    }
}

/// Receives the mod's reports, keeps the facts per session, and says when one arrived.
///
/// It is the app's side of the channel, without the socket: the listener hands it bodies, the
/// session store asks it for facts, and the refresh loop takes it as a trigger.
public final class CompanionHub: ChangeTrigger, @unchecked Sendable {
    private let lock = NSLock()
    private var facts: [String: CompanionFacts] = [:]
    private var listeners: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var received = 0
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Takes one report. Returns the event it held, or nil when it was dropped.
    @discardableResult
    public func receive(_ body: Data) -> CompanionEvent? {
        guard let event = CompanionEvent.decode(body, receivedAt: now()) else { return nil }
        apply(event)
        return event
    }

    public func apply(_ event: CompanionEvent) {
        let waiting: [AsyncStream<Void>.Continuation] = lock.withLock {
            received += 1
            let current = facts[event.sessionID] ?? CompanionFacts(lastReportAt: event.receivedAt)
            facts[event.sessionID] = current.applying(event)
            return Array(listeners.values)
        }
        waiting.forEach { $0.yield() }
    }

    /// The facts for every session that has reported, by conversation id.
    public func snapshot() -> [String: CompanionFacts] {
        lock.withLock { facts }
    }

    /// How many are waiting to be told of a report. A report that arrives before anyone listens
    /// wakes nobody; its facts are kept all the same and are there at the next read.
    var listenerCount: Int { lock.withLock { listeners.count } }

    /// How many reports were taken since launch, for the set-up page and the log.
    public var reportCount: Int { lock.withLock { received } }

    /// Forgets sessions that are no longer listed, so the facts do not grow for ever.
    public func keep(only sessionIDs: Set<String>) {
        lock.withLock { facts = facts.filter { sessionIDs.contains($0.key) } }
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        lock.withLock { listeners[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { _ = self.listeners.removeValue(forKey: id) }
        }
        return stream
    }
}

/// Where the app and the mod meet: a socket, and a small file that says where the socket is and
/// holds the secret. Both are readable by their owner only.
public struct CompanionPaths: Sendable, Equatable {
    public var directory: URL
    /// Where the socket goes when the folder's own path is too long for one.
    public var fallbackDirectory: URL

    public init(
        directory: URL = PorchlightPaths.stateDirectory(),
        fallbackDirectory: URL = URL(fileURLWithPath: "/tmp/porchlight-\(getuid())", isDirectory: true)
    ) {
        self.directory = directory
        self.fallbackDirectory = fallbackDirectory
    }

    /// The longest path a Unix socket can have on macOS, less the terminating byte.
    public static let longestSocketPath = 103

    /// In Porchlight's folder when its path is short enough for a socket, which a long user name
    /// can prevent; otherwise in a private folder under /tmp.
    public var socket: URL {
        let preferred = directory.appendingPathComponent("companion.sock")
        return preferred.path.utf8.count <= Self.longestSocketPath ? preferred : fallbackDirectory.appendingPathComponent("companion.sock")
    }

    public var socketPathFits: Bool { socket.path.utf8.count <= Self.longestSocketPath }

    /// The one file the mod looks for: `{"v":1,"socket":"…","secret":"…"}`.
    public var descriptor: URL { directory.appendingPathComponent("companion.json") }

    /// Writes a fresh secret, with where the socket is, and returns the secret. A new one per
    /// launch: a mod reads the file again when it is refused. The secret only keeps other users
    /// and sandboxed programs out; anything running as the same user could read it.
    public func writeDescriptor() throws -> String {
        var generator = SystemRandomNumberGenerator()
        let value = (0..<24).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: socket.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let body = try JSONSerialization.data(withJSONObject: ["v": CompanionEvent.version, "socket": socket.path, "secret": value], options: [.sortedKeys])
        // Created empty with its final mode, then written: never readable by others in between.
        try? FileManager.default.removeItem(at: descriptor)
        guard FileManager.default.createFile(atPath: descriptor.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileHandle(forWritingTo: descriptor).write(contentsOf: body)
        return value
    }

    /// Removes the file, so a mod finds nothing to talk to once the app is gone.
    public func removeDescriptor() {
        try? FileManager.default.removeItem(at: descriptor)
    }
}
