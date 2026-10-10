import Foundation

/// How to recognise a session that stopped on a passing failure (a limit, a sleeping laptop, an
/// API that was down) rather than on a question, and what to offer for it.
///
/// The patterns are settings, not code: `transientErrors` in `settings.json`. The defaults are
/// taken from the messages Claude Code's error reference lists.
public struct TransientErrors: Sendable, Equatable, Codable {
    /// Regular expressions, matched without regard to case. One that does not compile is kept
    /// here, so a save does not lose it, and skipped when matching.
    public var patterns: [String]
    /// What Retry puts on the clipboard for the user to send. Claude Code's own advice for a
    /// response that was cut off is to reply "continue".
    public var resend: String

    /// Retrying by itself, through the companion mod. Nil is off, which is the default: a retry
    /// spends the user's Claude usage, so it happens only once they turned this on.
    public var autoRetry: AutoRetry?

    public static let defaultResend = "continue"

    /// Each default names a whole message, never a bare word like "limit": a question that only
    /// mentions a rate limit must not look like a failure.
    public static let defaultPatterns: [String] = [
        // Rate limits: short-lived throttles.
        #"temporarily limiting requests"#,
        #"request rejected \(429\)"#,
        #"\brate limit (exceeded|reached)\b"#,
        #"\brate_limit_error\b"#,
        #"\btoo many requests\b"#,
        // Usage limits that reset by themselves. Spend limits and budgets are left out: they
        // need someone to raise them, and trying again does not help.
        #"\bhit your [\w-]+ limit\b"#,
        #"\busage limit (reached|exceeded)\b"#,
        // The machine slept.
        #"\b(computer|machine|laptop|mac|system) went to sleep\b"#,
        #"\bwent to sleep (mid-response|before a response)\b"#,
        #"\bcomputer was asleep\b"#,
        // The API was unavailable or overloaded.
        #"\bapi error: (5\d\d\b|repeated 529|connection lost|the response stopped|server error|no response from api)"#,
        #"\b529 overloaded\b|\boverloaded_error\b|\bapi is at capacity\b|\bexperiencing high load\b"#,
        #"\bunable to connect to api\b"#,
        #"\b(connection lost|response stalled) before a response\b"#,
    ]

    public init(patterns: [String] = TransientErrors.defaultPatterns, resend: String = TransientErrors.defaultResend) {
        self.patterns = patterns
        let trimmed = resend.trimmingCharacters(in: .whitespacesAndNewlines)
        self.resend = trimmed.isEmpty ? Self.defaultResend : trimmed
    }

    private enum CodingKeys: String, CodingKey {
        case patterns, resend, autoRetry
    }

    /// Read as tolerantly as the other settings: a missing or mistyped list means the defaults,
    /// an entry that is not text is skipped on its own, and an empty list turns detection off.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let patterns = (try? c.decode(LossyArray<String>.self, forKey: .patterns))?.elements
        self.init(
            patterns: patterns ?? Self.defaultPatterns,
            resend: (try? c.decode(String.self, forKey: .resend)) ?? Self.defaultResend)
        // Absent, null or not what it should be: off. It is never turned on by a guess.
        autoRetry = (try? c.decodeIfPresent(AutoRetry.self, forKey: .autoRetry)) ?? nil
    }

    /// Compiled on every call: there are a handful of patterns and a handful of waiting
    /// sessions, and a compiled expression cannot be kept in a value that crosses threads.
    private static func compile(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// The patterns that cannot be used, for a settings screen or a bug report.
    public var unusablePatterns: [String] {
        patterns.filter { Self.compile($0) == nil }
    }

    /// The first pattern that matches the text, or nil.
    public func matchingPattern(in text: String) -> String? {
        let whole = NSRange(text.startIndex..., in: text)
        return patterns.first { pattern in
            Self.compile(pattern)?.firstMatch(in: text, range: whole) != nil
        }
    }

    public func matches(_ text: String) -> Bool {
        matchingPattern(in: text) != nil
    }

    /// Whether the session is waiting only because of a passing failure.
    ///
    /// Never for a session that asked a question or wants a tool approved, whatever words those
    /// contain: someone has to answer them, and a command that mentions a limit is not a failure.
    public func isTransientFailure(_ session: Session) -> Bool {
        guard session.needsHuman, session.questions.isEmpty, session.summary.waitingFor != "permission prompt" else { return false }
        var texts: [String] = []
        switch session.needs {
        case .question, .approval: return false
        case .other(let text): texts.append(text)
        case nil: break
        }
        if let detail = session.job?.detail { texts.append(detail) }
        return texts.contains(where: matches)
    }

    /// Whether Retry is offered: the session's mod reported a failure that may clear, or, without
    /// the mod, what Claude Code says of the session reads like one.
    public func offersRetry(_ session: Session) -> Bool {
        session.retryTarget != nil || isTransientFailure(session)
    }
}

/// What Retry does for one session: open it in the terminal, with a line to send on the clipboard.
///
/// Nothing is sent to the session and nothing is restarted. `claude respawn` only restarts the
/// process (spec §11, S2), so the retry is the user's own reply, one paste away.
public struct RetryPlan: Sendable, Equatable {
    /// `claude attach <id>`, in the session's repository.
    public let command: TerminalCommand
    /// The text to put on the clipboard once the terminal is open.
    public let resend: String

    /// Nil unless the session is waiting on a passing failure.
    public init?(session: Session, settings: TransientErrors = TransientErrors(), claude: String) {
        guard settings.offersRetry(session) else { return nil }
        command = .attach(to: session, claude: claude)
        resend = settings.resend
    }
}

public enum RetryOutcome: Sendable, Equatable {
    /// The session is not waiting on a passing failure; nothing was opened or copied.
    case notRetryable
    /// The terminal was asked to open the session. `resendCopied` says whether the resend line
    /// is on the clipboard.
    case launched(LaunchOutcome, resendCopied: Bool)
}

public enum Retry {
    /// Carries out a retry: opens the session, then copies the resend line.
    ///
    /// The copy comes second and only after the terminal took the command. A launcher that could
    /// not drive the terminal has put the command itself on the clipboard, and that must stay.
    public static func run(
        session: Session, settings: TransientErrors = TransientErrors(), claude: String,
        launcher: any TerminalLauncher, copy: @Sendable (String) async -> Bool
    ) async -> RetryOutcome {
        guard let plan = RetryPlan(session: session, settings: settings, claude: claude) else { return .notRetryable }
        let outcome = await launcher.open(plan.command)
        switch outcome {
        case .opened, .alreadyOpen, .switchedInTab, .agentViewFocused:
            return .launched(outcome, resendCopied: await copy(plan.resend))
        case .copiedToClipboard, .failed:
            return .launched(outcome, resendCopied: false)
        }
    }
}

/// When and how often a failed turn is tried again without the user.
public struct AutoRetry: Sendable, Equatable, Codable {
    /// How long after the failure the first retry is sent. Each later one waits twice as long as
    /// the one before, up to an hour. Never under a minute: Claude Code has already retried for
    /// some minutes by the time it reports a failure.
    public var after: TimeInterval
    /// How many failures in a row are retried before it is left to the user.
    public var attempts: Int

    public static let defaultAfter: TimeInterval = 300
    public static let defaultAttempts = 3
    static let longestWait: TimeInterval = 3600

    public init(after: TimeInterval = AutoRetry.defaultAfter, attempts: Int = AutoRetry.defaultAttempts) {
        self.after = min(max(after, 60), Self.longestWait)
        self.attempts = min(max(attempts, 1), 10)
    }

    private enum CodingKeys: String, CodingKey { case after, attempts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            after: (try? c.decode(TimeInterval.self, forKey: .after)) ?? Self.defaultAfter,
            attempts: (try? c.decode(Int.self, forKey: .attempts)) ?? Self.defaultAttempts)
    }

    /// The wait before the retry of the `n`th failure in a row, from 1.
    public func wait(beforeAttempt n: Int) -> TimeInterval {
        min(after * pow(2, Double(max(n, 1) - 1)), Self.longestWait)
    }

    /// What will be done about a failure, or was.
    public enum Standing: Sendable, Equatable {
        /// A retry will be sent at this time: attempt `attempt` of `of`.
        case scheduled(at: Date, attempt: Int, of: Int)
        /// This many were retried and failed again; the rest is the user's.
        case exhausted(attempts: Int)
    }

    public func standing(for target: RetryTarget) -> Standing {
        guard target.failuresInARow <= attempts else { return .exhausted(attempts: attempts) }
        return .scheduled(at: target.failedAt + wait(beforeAttempt: target.failuresInARow), attempt: target.failuresInARow, of: attempts)
    }
}
