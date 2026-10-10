import Foundation
import Testing

@testable import PorchlightCore

private let conversation = "22222222-0000-4000-8000-000000000000"
private let start = Date(timeIntervalSince1970: 1_791_540_000)

private func report(_ fields: [String: Any]) -> Data {
    var all: [String: Any] = ["v": 1, "session": conversation]
    fields.forEach { all[$0] = $1 }
    return try! JSONSerialization.data(withJSONObject: all)
}

private func failure(_ kind: String = "rate_limit", id: String? = "f1-5", retry: Bool = true) -> [String: Any] {
    var fields: [String: Any] = ["kind": "failure", "error": kind]
    if let id { fields["id"] = id }
    if retry { fields["can"] = ["retry"] }
    return fields
}

/// A session as the store would hand it on after these reports, each a minute after the last.
private func session(_ reports: [[String: Any]], state: SessionState = .blocked) -> Session {
    let clock = RetryClock()
    let hub = CompanionHub(now: { clock.now })
    for one in reports {
        hub.receive(report(one))
        clock.now += 60
    }
    return Session(summary: SessionSummary(id: "22222222", sessionId: conversation.uppercased(), name: "fails", state: state), companion: hub.snapshot()[conversation])
}

private final class RetryClock: @unchecked Sendable {
    var now = start
}

@Suite struct CompanionRetryTests {
    @Test func aFailureReportCarriesItsIdAndWhetherARetryIsTaken() throws {
        let event = try #require(CompanionEvent.decode(report(failure()), receivedAt: start))
        #expect(event.kind == .failure(kind: "rate_limit") && event.failureID == "f1-5" && event.takesRetry)
        #expect(CompanionEvent.decode(report(failure(retry: false)), receivedAt: start)?.takesRetry == false)
        #expect(CompanionEvent.decode(report(failure(id: "not an id")), receivedAt: start)?.failureID == nil)
        #expect(CompanionEvent.decode(report(failure(id: "not an id")), receivedAt: start)?.takesRetry == false)
        // An older mod's report: a failure, with nothing to retry it by.
        let old = try #require(CompanionEvent.decode(report(["kind": "failure", "error": "overloaded"]), receivedAt: start))
        #expect(old.failureID == nil && !old.takesRetry)
        // Only a failure has them.
        #expect(CompanionEvent.decode(report(["kind": "turn.start", "id": "f1-5", "can": ["retry"]]), receivedAt: start)?.failureID == nil)
    }

    @Test func aSessionIsARetryTargetOnlyWhileStoppedOnAFailureThatMayClear() throws {
        let target = try #require(session([["kind": "turn.start"], failure()]).retryTarget)
        #expect(target == RetryTarget(sessionID: conversation, failureID: "f1-5", failureClass: "rate_limit", failedAt: start + 60, failuresInARow: 1))
        #expect(target.failureName == "a rate limit")
        // The failed turn's own end changes nothing.
        #expect(session([failure(), ["kind": "turn.complete", "reason": "error"]]).retryTarget?.failureID == "f1-5")

        // A class that needs a person, whatever the mod says; a mod that takes no retry; no mod.
        for kind in ["authentication_failed", "billing_error", "invalid_request", "model_not_found", "unknown"] {
            #expect(session([failure(kind)]).retryTarget == nil)
        }
        #expect(session([failure(retry: false)]).retryTarget == nil)
        #expect(session([failure(id: nil)]).retryTarget == nil)
        #expect(Session(summary: SessionSummary(id: "a", sessionId: conversation, name: "n", state: .blocked)).retryTarget == nil)
        // A new turn, a question or an approval since, the session's end, or a session not waiting.
        #expect(session([failure(), ["kind": "turn.start"]]).retryTarget == nil)
        #expect(session([failure(), ["kind": "permission", "tool": "Bash", "detail": "make"]]).retryTarget == nil)
        #expect(session([failure(), ["kind": "session.end"]]).retryTarget == nil)
        #expect(session([failure()], state: .working).retryTarget == nil)
    }

    @Test func failuresInARowAreCountedUntilATurnAnswers() {
        let again: [String: Any] = ["kind": "turn.start"]
        let failedEnd: [String: Any] = ["kind": "turn.complete", "reason": "error"]
        let twice = session([failure(id: "f1-1"), failedEnd, again, failure(id: "f2-2"), failedEnd])
        #expect(twice.retryTarget?.failuresInARow == 2 && twice.retryTarget?.failureID == "f2-2")
        // When the second failure was reported, not the first.
        #expect(twice.retryTarget?.failedAt == start + 180)
        // The mod says again what is open every minute: the same failure counts once, from its first report.
        let repeated = session([failure(id: "f1-1"), failure(id: "f1-1"), failure(id: "f1-1")])
        #expect(repeated.retryTarget?.failuresInARow == 1 && repeated.retryTarget?.failedAt == start)
        // A turn that answered starts the count again; one that was interrupted does not.
        let recovered = session([failure(id: "f1-1"), again, ["kind": "turn.complete", "reason": "answer"], again, failure(id: "f2-2")])
        #expect(recovered.retryTarget?.failuresInARow == 1)
        let interrupted = session([failure(id: "f1-1"), again, ["kind": "turn.complete", "reason": "aborted"], again, failure(id: "f2-2")])
        #expect(interrupted.retryTarget?.failuresInARow == 2)
    }

    @Test func aRetryNamesTheFailureAndCarriesOneShortLine() throws {
        let target = RetryTarget(sessionID: conversation, failureID: "f1-5", failureClass: "overloaded", failedAt: start, failuresInARow: 1)
        let command = try #require(target.command(text: "  continue \n"))
        let sent = try #require(JSONSerialization.jsonObject(with: command) as? [String: Any])
        #expect(sent["type"] as? String == "retry" && sent["id"] as? String == "f1-5" && sent["text"] as? String == "continue" && sent["v"] as? Int == 1)
        #expect(sent.count == 4)
        // Not a line, or too long for the mod to take: no command at all.
        #expect(target.command(text: "") == nil && target.command(text: "two\nlines") == nil)
        #expect(target.command(text: String(repeating: "x", count: 201)) == nil)
        #expect(target.command(text: String(repeating: "x", count: 200)) != nil)
    }

    @Test func theWaitDoublesAndTheCapEndsIt() throws {
        let auto = AutoRetry(after: 300, attempts: 3)
        #expect((1...5).map { auto.wait(beforeAttempt: $0) } == [300, 600, 1200, 2400, 3600])
        func target(_ n: Int) -> RetryTarget { RetryTarget(sessionID: conversation, failureID: "f\(n)-1", failureClass: "rate_limit", failedAt: start, failuresInARow: n) }
        #expect(auto.standing(for: target(1)) == .scheduled(at: start + 300, attempt: 1, of: 3))
        #expect(auto.standing(for: target(3)) == .scheduled(at: start + 1200, attempt: 3, of: 3))
        #expect(auto.standing(for: target(4)) == .exhausted(attempts: 3))

        // Never under a minute, never over an hour, between one and ten tries.
        #expect(AutoRetry(after: 5, attempts: 0) == AutoRetry(after: 60, attempts: 1))
        #expect(AutoRetry(after: 99_999, attempts: 99) == AutoRetry(after: 3600, attempts: 10))
    }

    @Test func automaticRetryIsOffUnlessTheSettingsSaySo() throws {
        func settings(_ json: String) throws -> TransientErrors { try JSONDecoder().decode(TransientErrors.self, from: Data(json.utf8)) }
        #expect(TransientErrors().autoRetry == nil)
        #expect(try settings("{}").autoRetry == nil)
        #expect(try settings(#"{"autoRetry":null}"#).autoRetry == nil)
        #expect(try settings(#"{"autoRetry":"yes"}"#).autoRetry == nil)
        #expect(try settings(#"{"autoRetry":true}"#).autoRetry == nil)
        // An object turns it on; a field that is not what it should be falls back on its own.
        #expect(try settings(#"{"autoRetry":{}}"#).autoRetry == AutoRetry())
        #expect(try settings(#"{"autoRetry":{"after":900,"attempts":"many"}}"#).autoRetry == AutoRetry(after: 900, attempts: 3))
        // And it survives a save.
        var on = TransientErrors(resend: "go on")
        on.autoRetry = AutoRetry(after: 900, attempts: 2)
        let saved = try JSONDecoder().decode(TransientErrors.self, from: JSONEncoder().encode(on))
        #expect(saved == on)
        #expect(try JSONDecoder().decode(TransientErrors.self, from: JSONEncoder().encode(TransientErrors())).autoRetry == nil)
    }

    @Test func theRowOffersRetryForAReportedFailureAndSaysWhatWillHappen() {
        let failed = session([failure("server_error")])
        var settings = TransientErrors()
        // Nothing Claude Code says of this session reads like a failure: the mod's report is why.
        #expect(!settings.isTransientFailure(failed) && settings.offersRetry(failed))
        let plain = InboxRow(session: failed, transientErrors: settings, now: start + 30)
        #expect(plain.isRetryable && plain.retry?.failureID == "f1-5" && plain.autoRetry == nil && plain.autoRetryWhen == nil)

        settings.autoRetry = AutoRetry(after: 300, attempts: 3)
        #expect(InboxRow(session: failed, transientErrors: settings, now: start + 30).autoRetryWhen == "in 5 min")
        #expect(InboxRow(session: failed, transientErrors: settings, now: start + 250).autoRetryWhen == "in a minute")
        #expect(InboxRow(session: failed, transientErrors: settings, now: start + 400).autoRetryWhen == "now")
        // A failure that needs a person: no Retry from the report, whatever is turned on.
        let needsPerson = InboxRow(session: session([failure("billing_error")]), transientErrors: settings, now: start)
        #expect(!needsPerson.isRetryable && needsPerson.retry == nil && needsPerson.autoRetry == nil)
    }
}
