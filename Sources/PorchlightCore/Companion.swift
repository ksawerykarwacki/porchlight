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
    /// For a question: the mod's own name for this asking of it. An answer must name it, so one
    /// meant for an earlier question can never land on a later one.
    public var questionID: String?
    /// For a question: whether this mod will take an answer from the app at all.
    public var takesAnswer = false
    /// With a turn's end: the end of what the session said last. Never part of `line`.
    public var said: String?
    /// For a failure: the mod's own name for it, and whether the mod will submit a retry for it
    /// on the app's word. A retry must name the failure, so a late one cannot land on another.
    public var failureID: String?
    public var takesRetry = false
    /// With a turn's end: the mod's own name for it, and whether the mod will submit a reply to
    /// it on the app's word. A reply must name the turn, so a late one cannot start another.
    public var turnID: String?
    public var takesReply = false

    public init(sessionID: String, kind: Kind, receivedAt: Date, questionID: String? = nil, takesAnswer: Bool = false) {
        self.sessionID = sessionID
        self.kind = kind
        self.receivedAt = receivedAt
        self.questionID = questionID
        self.takesAnswer = takesAnswer
    }

    /// A question's id as the mod makes it: short, and nothing but letters, digits and dashes.
    public static func isValidQuestionID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// The version of the reports this build understands.
    public static let version = 1
    /// The longest text kept from a report; the rest is cut.
    static let textLimit = 2000
    /// How much is kept of what a session said last.
    static let saidLimit = 2000

    private struct Body: Decodable {
        let v: Int?
        let session: String?
        let kind: String?
        let reason: String?
        let questions: LossyArray<JobState.Question>?
        let tool: String?
        let detail: String?
        let error: String?
        let id: String?
        let said: String?
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
        var event = CompanionEvent(sessionID: session.lowercased(), kind: kind, receivedAt: receivedAt)
        if case .turnComplete = kind, let said = body.said?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty {
            // Its end is what matters: that is where a session says what it needs.
            event.said = String(said.suffix(saidLimit))
        }
        if case .turnComplete = kind, let id = body.id, isValidQuestionID(id) {
            event.turnID = id
            let can = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["can"] as? [Any]
            event.takesReply = can?.contains { $0 as? String == "reply" } ?? false
        }
        if case .failure = kind, let id = body.id, isValidQuestionID(id) {
            event.failureID = id
            let can = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["can"] as? [Any]
            event.takesRetry = can?.contains { $0 as? String == "retry" } ?? false
        }
        if case .question = kind, let id = body.id, isValidQuestionID(id) {
            event.questionID = id
            // Read on its own, so a `can` that is not a list costs the report nothing but this.
            let can = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["can"] as? [Any]
            event.takesAnswer = can?.contains { $0 as? String == "answer" } ?? false
        }
        return event
    }
}

extension CompanionEvent {
    /// One line for a person: which session, and what it said.
    public var line: String {
        let what: String
        switch kind {
        case .sessionStart: what = "started"
        case .sessionEnd: what = "ended"
        case .turnStart: what = "turn started"
        case .turnComplete(let reason): what = "turn finished" + (reason.map { " (\($0))" } ?? "")
        case .question(let questions): what = "asks: " + questions.map(\.question).joined(separator: " / ")
        case .permission(let tool, let detail): what = "wants approval for \(tool): \(detail)"
        case .resumed: what = "is working again"
        case .failure(let kind): what = "failed: \(kind)"
        }
        return "\(sessionID.prefix(8))  \(what)"
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
    /// For a question the mod will take an answer to: its id. Nil for anything else.
    public var answerableQuestionID: String?
    /// The class of the failure the last turn ended on; cleared when a turn starts.
    public var failure: String?
    /// That failure's id, when the mod will submit a retry for it; and when it was first reported.
    public var retryableFailureID: String?
    public var failedAt: Date?
    /// How many turns in a row ended on a failure. A turn that answers starts the count again.
    public var failuresInARow = 0
    /// The last failure counted, so that one said again (the mod repeats what is open) counts once.
    var countedFailureID: String?
    /// The id of the last finished turn, when the mod will submit a reply to it; cleared when a
    /// turn starts or the session stops on something else.
    public var replyableTurnID: String?
    /// The end of what the session said in its last finished turn; cleared when a turn starts.
    /// Kept in memory only: it is the session's own words, and is never logged or written down.
    public var lastSaid: String?
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
            next.answerableQuestionID = nil
            next.failure = nil
            next.retryableFailureID = nil
            next.failedAt = nil
            next.replyableTurnID = nil
            next.lastSaid = nil
        case .turnComplete:
            next.lastSaid = event.said
            next.replyableTurnID = event.takesReply ? event.turnID : nil
            // A turn that answered: whatever failed before it has passed.
            if case .turnComplete(let reason) = event.kind, reason == "answer" {
                next.failuresInARow = 0
                next.countedFailureID = nil
            }
            next.isTurnRunning = false
            next.waiting = nil
            next.waitingSince = nil
            next.answerableQuestionID = nil
        case .question(let questions):
            // The mod says again what is open every so often, in case the app was restarted
            // meanwhile: the same thing reported twice has been waiting since the first time.
            if waiting != .question(questions) { next.waitingSince = event.receivedAt }
            next.waiting = .question(questions)
            next.answerableQuestionID = event.takesAnswer ? event.questionID : nil
        case .permission(let tool, let detail):
            if waiting != .permission(tool: tool, detail: detail) { next.waitingSince = event.receivedAt }
            next.waiting = .permission(tool: tool, detail: detail)
            next.answerableQuestionID = nil
        case .resumed:
            next.waiting = nil
            next.waitingSince = nil
            next.answerableQuestionID = nil
        case .failure(let kind):
            next.failure = kind
            next.replyableTurnID = nil
            next.isTurnRunning = false
            next.retryableFailureID = event.takesRetry ? event.failureID : nil
            // Without an id every report is taken for a new failure, as an older mod's would be.
            if event.failureID == nil || event.failureID != countedFailureID {
                next.failuresInARow += 1
                next.countedFailureID = event.failureID
                next.failedAt = event.receivedAt
            }
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
    /// Told of every report as it is taken; for the command-line tool, which prints them.
    private let onEvent: (@Sendable (CompanionEvent) -> Void)?

    public init(now: @escaping @Sendable () -> Date = { Date() }, onEvent: (@Sendable (CompanionEvent) -> Void)? = nil) {
        self.now = now
        self.onEvent = onEvent
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
        onEvent?(event)
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

/// A question Porchlight may answer for the user: one question, with options of which one is
/// chosen, asked in a session whose mod said it takes answers.
public struct AnswerTarget: Sendable, Equatable {
    /// The conversation's id, which is how the mod's requests are told apart.
    public let sessionID: String
    public let questionID: String
    public let question: String
    /// The options' labels exactly as the session wrote them.
    public let options: [String]

    public init(sessionID: String, questionID: String, question: String, options: [String]) {
        self.sessionID = sessionID
        self.questionID = questionID
        self.question = question
        self.options = options
    }

    /// The command that answers with one of the options, or nil when there is no such option.
    /// Only ever built from a choice the user made in Porchlight: nothing here picks for them.
    public func command(choosing index: Int) -> Data? {
        guard options.indices.contains(index) else { return nil }
        let body: [String: Any] = ["v": CompanionEvent.version, "type": "answer", "id": questionID, "answers": [question: options[index]]]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

extension Session {
    /// The question that can be answered from Porchlight, if this session is waiting on one.
    ///
    /// Several questions at once, a choice of several options, typed text and a session without
    /// the mod are all left to the session's own dialog.
    public var answerTarget: AnswerTarget? {
        guard needsHuman, let conversation = summary.sessionId, let companion, let id = companion.answerableQuestionID,
              case .question(let asked)? = companion.waiting, asked.count == 1, let only = asked.first,
              !only.multiSelect, !only.options.isEmpty,
              // What the row shows must be what would be answered.
              questions == asked else { return nil }
        return AnswerTarget(sessionID: conversation.lowercased(), questionID: id, question: only.question, options: only.options.map(\.label))
    }
}

/// A failure Porchlight may have retried: the session stopped on it, it is of a class that may
/// clear by itself, and the session's mod said it will submit a retry for it.
public struct RetryTarget: Sendable, Equatable {
    /// The conversation's id, which is how the mod's requests are told apart.
    public let sessionID: String
    public let failureID: String
    /// Claude Code's class for the failure: `rate_limit`, `overloaded` or `server_error`.
    public let failureClass: String
    public let failedAt: Date
    /// Which failure in a row this is, from 1.
    public let failuresInARow: Int

    /// The API's classes for a failure that may clear by itself. The mod judges the same way;
    /// the app does not take its word alone.
    public static let clearingClasses: Set<String> = ["rate_limit", "overloaded", "server_error"]
    /// The longest line the mod will submit.
    public static let textLimit = 200

    /// The class in words, for a row.
    public var failureName: String {
        switch failureClass {
        case "rate_limit": "a rate limit"
        case "overloaded": "an overloaded API"
        default: "a server error"
        }
    }

    /// The command that has the mod submit `text`, or nil when the text is not one short line.
    /// The text is the user's own resend line from the settings: nothing here writes one.
    public func command(text: String) -> Data? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.count <= Self.textLimit, !line.contains(where: \.isNewline) else { return nil }
        let body: [String: Any] = ["v": CompanionEvent.version, "type": "retry", "id": failureID, "text": line]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

extension Session {
    /// The failure that can be retried through the mod, if this session stopped on one and is
    /// still stopped on it.
    public var retryTarget: RetryTarget? {
        guard needsHuman, let conversation = summary.sessionId, let companion, companion.waiting == nil, !companion.isTurnRunning,
              let failure = companion.failure, RetryTarget.clearingClasses.contains(failure),
              let id = companion.retryableFailureID, let failedAt = companion.failedAt else { return nil }
        return RetryTarget(
            sessionID: conversation.lowercased(), failureID: id, failureClass: failure, failedAt: failedAt, failuresInARow: max(companion.failuresInARow, 1))
    }
}

/// A session Porchlight may send the user's reply to: it finished a turn, sits idle, and its mod
/// said it will submit a reply for that turn's end.
public struct ReplyTarget: Sendable, Equatable {
    /// The conversation's id, which is how the mod's requests are told apart.
    public let sessionID: String
    public let turnID: String

    /// The longest reply the mod will submit.
    public static let textLimit = 4000

    public init(sessionID: String, turnID: String) {
        self.sessionID = sessionID
        self.turnID = turnID
    }

    /// The command that has the mod submit `text` as the user's words, or nil when there is
    /// nothing to send or it is too long. The text is what the user typed and sent in
    /// Porchlight: nothing here writes one.
    public func command(text: String) -> Data? {
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reply.isEmpty, reply.count <= Self.textLimit else { return nil }
        let body: [String: Any] = ["v": CompanionEvent.version, "type": "reply", "id": turnID, "text": reply]
        return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}

extension Session {
    /// Where a reply typed in Porchlight can go, if this session is waiting for the user after a
    /// finished turn. Not while it waits on a question, an approval or a failure: those have
    /// their own answers.
    public var replyTarget: ReplyTarget? {
        guard needsHuman, let conversation = summary.sessionId, let companion, companion.waiting == nil, !companion.isTurnRunning,
              companion.failure == nil, let id = companion.replyableTurnID else { return nil }
        return ReplyTarget(sessionID: conversation.lowercased(), turnID: id)
    }
}
