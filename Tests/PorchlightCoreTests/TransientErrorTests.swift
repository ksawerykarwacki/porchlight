import Foundation
import Testing

@testable import PorchlightCore

/// A session as the store would hand it over, with the job file's waiting text. The fixtures
/// hold no failed session, so these are built from the same JSON shape.
func session(
    _ id: String = "aaaa1111", state: SessionState = .blocked, needs: String? = nil, detail: String? = nil,
    waitingFor: String? = nil, questions: Bool = false, cwd: String = "/Users/u/code/alpha"
) throws -> Session {
    var job: [String: Any] = ["state": "working", "name": "session \(id)", "tempo": "blocked"]
    job["needs"] = needs
    job["detail"] = detail
    if questions {
        job["block"] = ["questions": [["question": "Which one?", "options": [["label": "A"], ["label": "B"]]]]]
    }
    let decoded = try JSONDecoder().decode(JobState.self, from: JSONSerialization.data(withJSONObject: job))
    return Session(
        summary: SessionSummary(id: id, name: "session \(id)", cwd: cwd, state: state, waitingFor: waitingFor),
        job: decoded, observedBlockedSince: noon - 600)
}

@Suite struct TransientErrorTests {
    let defaults = TransientErrors()

    func decode(_ json: String) throws -> TransientErrors {
        try JSONDecoder().decode(TransientErrors.self, from: Data(json.utf8))
    }

    @Test func theDefaultsRecogniseTheFourKnownFailures() {
        let failures: [String: [String]] = [
            "rate limit": [
                "API Error: Server is temporarily limiting requests (not your usage limit)",
                "API Error: Request rejected (429) · this may be a temporary capacity issue. If it persists, check https://status.claude.com.",
                "Rate limit exceeded, try again later",
                "429 Too Many Requests",
                #"{"type":"error","error":{"type":"rate_limit_error"}}"#,
            ],
            "usage limit": [
                "You've hit your session limit · resets 3:45pm",
                "You've hit your weekly limit · resets Mon 12:00am",
                "You've hit your Opus limit · resets 3:45pm",
                "You’ve hit your 5-hour limit",
                "Claude usage limit reached. Your limit will reset at 4pm.",
            ],
            "went to sleep": [
                "API Error: Your computer went to sleep mid-response. The response above may be incomplete.",
                "Your computer went to sleep before a response was produced",
                "Connection lost while your computer was asleep",
                "The laptop went to sleep",
            ],
            "API unavailable": [
                "API Error: 500 Internal server error. This is a server-side issue, usually temporary — try again in a moment.",
                "API Error: Repeated 529 Overloaded errors. The API is at capacity — this is usually temporary.",
                "529 Overloaded",
                "Opus is experiencing high load, please use /model to switch to Sonnet",
                "Unable to connect to API",
                "Connection lost before a response was produced",
                "The response stalled before a response was produced",
                "API Error: Connection lost mid-response. The response above may be incomplete.",
                "API Error: The response stopped arriving. The response above may be incomplete.",
                "API Error: No response from API (waited 3m, then 10m on the retry).",
                #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
            ],
        ]
        #expect(failures.count == 4)
        for (failure, texts) in failures {
            for text in texts {
                #expect(defaults.matches(text), "\(failure): \(text)")
            }
        }
        // Whatever the letters' case.
        #expect(defaults.matches("YOU'VE HIT YOUR SESSION LIMIT"))
        #expect(defaults.matches("api error: 503 service unavailable"))
    }

    @Test func aQuestionThatOnlyMentionsALimitIsNotAFailure() {
        let ordinary = [
            "should I raise the rate limit to 100?",
            "Should the rate limit be per user or per IP?",
            "The API has a rate limit of 60 requests a minute. Which client should handle the backoff?",
            "Do you want a usage limit per account, or a spend limit per team?",
            "Which API error type should I catch here?",
            "Should I add a sleep(1) before the retry, or let the worker go to sleep?",
            "The method is overloaded three times. Keep all three?",
            "The test returns 500 Internal Server Error; should I fix the handler or the test?",
            "Should the limit for uploads be 10 MB?",
            "Which of the two timeouts should I raise?",
            "The request timed out in CI twice. Raise the timeout?",
            "Is the server at capacity planning stage yet?",
            "",
        ]
        for text in ordinary {
            #expect(!defaults.matches(text), "\(text)")
            #expect(defaults.matchingPattern(in: text) == nil)
        }
        // Limits someone has to raise are not passing failures either.
        #expect(!defaults.matches("You've hit your monthly spend limit · raise it at https://claude.ai/settings/usage"))
        #expect(!defaults.matches("You've hit your team's shared budget · ask your admin to raise it"))
    }

    @Test func thePatternsComeFromSettingsNotFromCode() throws {
        // A setting replaces the defaults outright.
        let custom = try decode(#"{"patterns":["flux capacitor (drained|empty)","\\bquota\\b"]}"#)
        #expect(custom.patterns == ["flux capacitor (drained|empty)", #"\bquota\b"#])
        #expect(custom.matches("The Flux Capacitor drained again"))
        #expect(custom.matchingPattern(in: "Out of quota for today") == #"\bquota\b"#)
        #expect(!custom.matches("You've hit your session limit · resets 3:45pm"))
        #expect(!custom.matches("flux capacitor is fine"))

        // Missing means the defaults; an empty list means none, which turns detection off.
        #expect(try decode("{}") == TransientErrors())
        #expect(try decode("{}").patterns == TransientErrors.defaultPatterns)
        let off = try decode(#"{"patterns":[]}"#)
        #expect(off.patterns.isEmpty)
        #expect(!off.matches("You've hit your session limit"))

        // What was read is what is written back.
        let again = try JSONDecoder().decode(TransientErrors.self, from: JSONEncoder().encode(custom))
        #expect(again == custom)
        #expect(try JSONDecoder().decode(TransientErrors.self, from: JSONEncoder().encode(off)) == off)
    }

    @Test func aBrokenPatternIsSkippedWithoutLosingTheOthers() throws {
        // An expression that does not compile, between two that do.
        let settings = try decode(#"{"patterns":["first failure","(unclosed","second failure"," "]}"#)
        #expect(settings.patterns.count == 4)
        #expect(settings.unusablePatterns == ["(unclosed", " "])
        #expect(settings.matches("the first failure happened"))
        #expect(settings.matchingPattern(in: "then the SECOND FAILURE") == "second failure")
        #expect(!settings.matches("(unclosed"))
        #expect(!settings.matches("an ordinary sentence with spaces"))

        // Entries that are not text are dropped one by one.
        let mixed = try decode(#"{"patterns":["first failure",42,null,{"pattern":"x"},["y"],"second failure"]}"#)
        #expect(mixed.patterns == ["first failure", "second failure"])
        #expect(mixed.matches("second failure"))

        // A list that is not a list falls back to the defaults, and keeps the other value.
        let odd = try decode(#"{"patterns":"rate limit","resend":"go on"}"#)
        #expect(odd.patterns == TransientErrors.defaultPatterns)
        #expect(odd.resend == "go on")
        #expect(try decode(#"{"patterns":["only this"],"resend":7}"#) == TransientErrors(patterns: ["only this"]))
        #expect(try decode(#"{"resend":"   "}"#).resend == "continue")

        // Every default compiles.
        #expect(TransientErrors().unusablePatterns.isEmpty)
        #expect(TransientErrors.defaultPatterns.count >= 4)
    }

    @Test func settingsJSONCarriesThePatternsAndToleratesOddNeighbours() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-transient-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Settings.fileURL(in: directory)
        #expect(url.path.hasPrefix(directory.path))

        try Data(#"{"terminal":"ghostty","preferAgentView":"maybe","transientErrors":{"patterns":["flux capacitor","(broken"]}}"#.utf8).write(to: url)
        let loaded = Settings.load(from: url)
        #expect(loaded.terminal == "ghostty")
        #expect(loaded.transientErrors?.patterns == ["flux capacitor", "(broken"])
        #expect(loaded.transientErrors?.matches("flux capacitor drained") == true)

        // An odd value for the whole entry means the defaults and costs nothing else.
        try Data(#"{"terminal":"warp","transientErrors":"none","reminders":{"ladder":[300,3600]}}"#.utf8).write(to: url)
        let odd = Settings.load(from: url)
        #expect(odd.transientErrors == nil)
        #expect(odd.terminal == "warp" && odd.reminders?.ladder == [300, 3600])

        // Saved alongside the rest and read back the same.
        let custom = Settings(terminal: "warp", reminders: ReminderSettings(hideDetails: true), transientErrors: TransientErrors(patterns: ["a", "b"], resend: "try again"))
        try custom.save(to: url)
        #expect(Settings.load(from: url) == custom)
        // A file without the entry stays without it.
        try Settings(terminal: "warp").save(to: url)
        #expect(Settings.load(from: url).transientErrors == nil)
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("transientErrors"))
    }

    @Test func onlyASessionWaitingOnTheFailureItselfCounts() throws {
        let limit = "You've hit your session limit · resets 3:45pm"
        // The failure as the waiting text, or as the one-line status.
        #expect(defaults.isTransientFailure(try session(needs: limit)))
        #expect(defaults.isTransientFailure(try session(needs: "Waiting for you", detail: "API Error: Repeated 529 Overloaded errors.")))
        #expect(defaults.isTransientFailure(try session(detail: "Your computer went to sleep before a response was produced")))

        // An ordinary wait, and a session with no job file at all.
        #expect(!defaults.isTransientFailure(try session(needs: "Which of the two timeouts should I raise?", detail: "waiting for a decision")))
        #expect(!defaults.isTransientFailure(waiting("plain", since: noon)))

        // A question or an approval is never a failure, even when its words match.
        #expect(!defaults.isTransientFailure(try session(needs: "answer: The log says \"\(limit)\". Wait or switch model? (Wait · Switch)")))
        #expect(!defaults.isTransientFailure(try session(needs: "approve Bash: echo \"\(limit)\" >> notes.txt")))
        #expect(!defaults.isTransientFailure(try session(needs: limit, questions: true)))
        #expect(!defaults.isTransientFailure(try session(needs: limit, waitingFor: "permission prompt")))

        // The job file keeps old text around after the session moves on.
        #expect(!defaults.isTransientFailure(try session(state: .working, needs: limit, detail: limit)))
        #expect(!defaults.isTransientFailure(try session(state: .done, needs: limit)))

        // With detection off nothing counts.
        #expect(!TransientErrors(patterns: []).isTransientFailure(try session(needs: limit)))
    }

    @Test func theRowSaysWhetherItCanBeRetried() throws {
        let failed = try session("f0f0f0f0", needs: "API Error: Server is temporarily limiting requests (not your usage limit)")
        let asking = try session("a0a0a0a0", needs: "should I raise the rate limit to 100?")
        #expect(InboxRow(session: failed, now: noon).isRetryable)
        #expect(InboxRow(session: failed, now: noon).kind == .waiting)
        #expect(!InboxRow(session: asking, now: noon).isRetryable)
        #expect(!InboxRow(session: waiting("plain", since: noon), now: noon).isRetryable)
        // A snoozed session can still be retried.
        #expect(InboxRow(session: failed, snooze: .until(noon + 3600), now: noon).isRetryable)

        // The row follows the patterns it is given, also through the grouped sections.
        let mine = TransientErrors(patterns: ["raise the rate limit"])
        #expect(!InboxRow(session: failed, transientErrors: mine, now: noon).isRetryable)
        #expect(InboxRow(session: asking, transientErrors: mine, now: noon).isRetryable)
        let groups = InboxGroups(sessions: [failed, asking], now: noon)
        #expect(groups.sections(now: noon).flatMap(\.rows).filter(\.isRetryable).map(\.id) == ["f0f0f0f0"])
        #expect(groups.sections(now: noon, transientErrors: mine).flatMap(\.rows).filter(\.isRetryable).map(\.id) == ["a0a0a0a0"])
    }
}
