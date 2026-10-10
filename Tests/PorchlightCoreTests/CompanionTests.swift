import Foundation
import Testing

@testable import PorchlightCore

private let conversation = "22222222-0000-4000-8000-000000000000"
private let start = Date(timeIntervalSince1970: 1_791_540_000)

private func body(_ fields: [String: Any]) -> Data {
    var all: [String: Any] = ["v": 1, "session": conversation]
    fields.forEach { all[$0] = $1 }
    return try! JSONSerialization.data(withJSONObject: all)
}

private func question(_ text: String, _ options: [String]) -> [String: Any] {
    ["question": text, "header": "x", "multiSelect": false, "options": options.map { ["label": $0, "description": ""] }]
}

@Suite struct CompanionEventTests {
    @Test func eachKindOfReportIsRead() throws {
        func kind(_ fields: [String: Any]) -> CompanionEvent.Kind? { CompanionEvent.decode(body(fields), receivedAt: start)?.kind }
        #expect(kind(["kind": "session.start"]) == .sessionStart)
        #expect(kind(["kind": "session.end"]) == .sessionEnd)
        #expect(kind(["kind": "turn.start"]) == .turnStart)
        #expect(kind(["kind": "turn.complete", "reason": "answer"]) == .turnComplete(reason: "answer"))
        #expect(kind(["kind": "turn.complete"]) == .turnComplete(reason: nil))
        #expect(kind(["kind": "resumed"]) == .resumed)
        #expect(kind(["kind": "failure", "error": "rate_limit"]) == .failure(kind: "rate_limit"))
        #expect(kind(["kind": "permission", "tool": "Bash", "detail": "touch a.txt"]) == .permission(tool: "Bash", detail: "touch a.txt"))
        guard case .question(let questions)? = kind(["kind": "question", "questions": [question("Apple or pear?", ["apple", "pear"])]]) else {
            Issue.record("expected a question")
            return
        }
        #expect(questions.count == 1 && questions[0].question == "Apple or pear?" && questions[0].options.map(\.label) == ["apple", "pear"])
        // The time is the app's, and the id is kept in one spelling.
        let upper = try #require(CompanionEvent.decode(body(["kind": "turn.start", "session": conversation.uppercased()]), receivedAt: start))
        #expect(upper.sessionID == conversation && upper.receivedAt == start)
    }

    @Test func whatIsNotAReportIsDropped() {
        let dropped: [Data] = [
            Data("not json".utf8), Data("[]".utf8), Data("{}".utf8),
            body(["kind": "turn.start", "session": "../../etc"]), body(["kind": "turn.start", "session": "22222222"]),
            body(["kind": "something.new"]), body(["kind": "turn.start", "v": 2]),
            body(["kind": "question", "questions": []]), body(["kind": "question"]), body(["kind": "question", "questions": ["nonsense", 7]]),
            body(["kind": "permission"]), body(["kind": "permission", "tool": ""]), body(["kind": "failure"]),
        ]
        for data in dropped { #expect(CompanionEvent.decode(data, receivedAt: start) == nil) }
        // A version left out is taken as the first; one broken question does not lose the others.
        var noVersion = try! JSONSerialization.jsonObject(with: body(["kind": "turn.start"])) as! [String: Any]
        noVersion["v"] = nil
        #expect(CompanionEvent.decode(try! JSONSerialization.data(withJSONObject: noVersion), receivedAt: start) != nil)
        let mixed = CompanionEvent.decode(body(["kind": "question", "questions": [7, question("Still here?", ["yes"])]]), receivedAt: start)
        #expect(mixed?.kind == .question(try! JSONDecoder().decode([JobState.Question].self, from: JSONSerialization.data(withJSONObject: [question("Still here?", ["yes"])]))))
        // Long text is cut, not refused.
        let long = CompanionEvent.decode(body(["kind": "permission", "tool": "Bash", "detail": String(repeating: "x", count: 9000)]), receivedAt: start)
        guard case .permission(_, let detail)? = long?.kind else {
            Issue.record("expected a permission")
            return
        }
        #expect(detail.count == CompanionEvent.textLimit)
    }

    @Test func theFactsFollowTheReportsInOrder() {
        let hub = CompanionHub(now: { start })
        func send(_ fields: [String: Any]) { hub.receive(body(fields)) }
        #expect(hub.snapshot().isEmpty)
        send(["kind": "session.start"])
        send(["kind": "turn.start"])
        #expect(hub.snapshot()[conversation]?.isTurnRunning == true && hub.snapshot()[conversation]?.waiting == nil)

        send(["kind": "question", "questions": [question("Apple or pear?", ["apple", "pear"])]])
        guard case .question(let asked)? = hub.snapshot()[conversation]?.waiting else {
            Issue.record("expected to be waiting on a question")
            return
        }
        #expect(asked[0].question == "Apple or pear?" && hub.snapshot()[conversation]?.waitingSince == start)
        send(["kind": "resumed"])
        #expect(hub.snapshot()[conversation]?.waiting == nil && hub.snapshot()[conversation]?.waitingSince == nil)

        send(["kind": "permission", "tool": "Bash", "detail": "rm -rf build"])
        #expect(hub.snapshot()[conversation]?.waiting == .permission(tool: "Bash", detail: "rm -rf build"))
        send(["kind": "turn.complete", "reason": "answer"])
        #expect(hub.snapshot()[conversation]?.waiting == nil && hub.snapshot()[conversation]?.isTurnRunning == false)

        // A failure is kept until the next turn starts.
        send(["kind": "failure", "error": "overloaded"])
        send(["kind": "turn.complete", "reason": "error"])
        #expect(hub.snapshot()[conversation]?.failure == "overloaded")
        send(["kind": "turn.start"])
        #expect(hub.snapshot()[conversation]?.failure == nil)

        // A restart forgets what was open; an end forgets the session.
        send(["kind": "question", "questions": [question("Still?", ["yes"])]])
        send(["kind": "session.start"])
        #expect(hub.snapshot()[conversation]?.waiting == nil)
        send(["kind": "session.end"])
        #expect(hub.snapshot().isEmpty)
        #expect(hub.reportCount == 12)

        // What was dropped changed nothing and was not counted.
        #expect(hub.receive(Data("junk".utf8)) == nil && hub.reportCount == 12)
    }

    @Test func aReportWakesWhoeverListensAndOldSessionsAreForgotten() async {
        let hub = CompanionHub(now: { start })
        var changes = hub.changes().makeAsyncIterator()
        hub.receive(body(["kind": "turn.start"]))
        await changes.next()
        // Several reports before anyone looks are one wake-up, not a backlog.
        hub.receive(body(["kind": "turn.complete"]))
        hub.receive(body(["kind": "turn.start"]))
        await changes.next()

        let other = "33333333-0000-4000-8000-000000000000"
        hub.receive(body(["kind": "turn.start", "session": other]))
        #expect(hub.snapshot().count == 2)
        hub.keep(only: [other])
        #expect(Array(hub.snapshot().keys) == [other])
    }

    @Test func theDescriptorHoldsAFreshSecretAndOnlyTheOwnerCanReadIt() throws {
        let directory = URL(fileURLWithPath: "/tmp/pl-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = CompanionPaths(directory: directory)
        let first = try paths.writeDescriptor()
        let second = try paths.writeDescriptor()
        #expect(first.count == 48 && second.count == 48 && first != second)
        let written = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: paths.descriptor)) as? [String: Any])
        #expect(written["secret"] as? String == second && written["socket"] as? String == paths.socket.path && written["v"] as? Int == 1)
        let mode = try #require(FileManager.default.attributesOfItem(atPath: paths.descriptor.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)
        paths.removeDescriptor()
        #expect(!FileManager.default.fileExists(atPath: paths.descriptor.path))
    }

    @Test func aFolderTooDeepForASocketGetsOneElsewhere() {
        let short = CompanionPaths(directory: URL(fileURLWithPath: "/Users/u/Library/Application Support/Porchlight"))
        #expect(short.socket.path == "/Users/u/Library/Application Support/Porchlight/companion.sock" && short.socketPathFits)
        let deep = CompanionPaths(
            directory: URL(fileURLWithPath: "/Users/" + String(repeating: "a", count: 90) + "/Library/Application Support/Porchlight"),
            fallbackDirectory: URL(fileURLWithPath: "/tmp/porchlight-501"))
        #expect(deep.socket.path == "/tmp/porchlight-501/companion.sock" && deep.socketPathFits)
        // The file that says where it is stays in the folder the mod knows.
        #expect(deep.descriptor.path.hasSuffix("/Library/Application Support/Porchlight/companion.json"))
    }
}

@Suite struct CompanionMergeTests {
    func job(question: String, updated: Date) throws -> JobState {
        let json: [String: Any] = [
            "state": "blocked", "name": "task", "needs": "answer: \(question)", "updatedAt": ISO8601DateFormatter().string(from: updated),
            "block": ["questions": [["question": question, "options": [["label": "old", "description": ""]]]]],
        ]
        return try JSONDecoder().decode(JobState.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func facts(_ fields: [String: Any], at date: Date) -> CompanionFacts? {
        let hub = CompanionHub(now: { date })
        hub.receive(body(fields))
        return hub.snapshot()[conversation]
    }

    func session(_ state: SessionState, job: JobState? = nil, companion: CompanionFacts? = nil) -> Session {
        Session(summary: SessionSummary(id: "22222222", sessionId: conversation, name: "task", state: state), job: job, companion: companion)
    }

    @Test func aNewerReportIsWhatTheSessionAsks() throws {
        let fromFile = try job(question: "The old question?", updated: start)
        let reported = facts(["kind": "question", "questions": [question("The new question?", ["a", "b"])]], at: start + 30)
        let merged = session(.blocked, job: fromFile, companion: reported)
        #expect(merged.questions.map(\.question) == ["The new question?"] && merged.questions[0].options.map(\.label) == ["a", "b"])
        #expect(merged.needs == .question("The new question?"))

        // With no job file at all, the report is all there is, and it is enough.
        let alone = session(.blocked, companion: reported)
        #expect(alone.questions.map(\.question) == ["The new question?"])
        let approval = session(.blocked, companion: facts(["kind": "permission", "tool": "Bash", "detail": "make deploy"], at: start))
        #expect(approval.needs == .approval(tool: "Bash", detail: "make deploy") && approval.questions.isEmpty)
    }

    @Test func theReportIsUsedInPlaceOfTheFileThatIsWrittenAMomentLater() throws {
        // The usual order: the mod reports as the question is asked, the file follows.
        let reported = facts(["kind": "question", "questions": [question("Apple or pear?", ["apple", "pear"])]], at: start)
        let moment = try job(question: "Apple or pear? (as the file words it)", updated: start + 0.4)
        #expect(session(.blocked, job: moment, companion: reported).questions.map(\.question) == ["Apple or pear?"])
        let atTheEdge = try job(question: "x", updated: start + Session.reportLead)
        #expect(session(.blocked, job: atTheEdge, companion: reported).questions.map(\.question) == ["Apple or pear?"])
    }

    @Test func theFileWinsWhenItIsClearlyLaterAndNothingChangesWithoutAReport() throws {
        let fromFile = try job(question: "The file's question?", updated: start + 60)
        let stale = facts(["kind": "question", "questions": [question("An earlier question?", ["a"])]], at: start)
        #expect(session(.blocked, job: fromFile, companion: stale).questions.map(\.question) == ["The file's question?"])

        // No report: exactly what the file says, as before the mod existed.
        let plain = session(.blocked, job: fromFile)
        #expect(plain.questions.map(\.question) == ["The file's question?"] && plain.needs == .question("The file's question?"))
        // A report that says "not waiting" does not hide what the file says.
        let quiet = facts(["kind": "turn.start"], at: start + 120)
        #expect(session(.blocked, job: fromFile, companion: quiet).questions.map(\.question) == ["The file's question?"])
    }

    @Test func theListStillDecidesWhetherASessionIsWaiting() {
        let reported = facts(["kind": "question", "questions": [question("Anyone?", ["yes"])]], at: start)
        // Claude Code says it is working: the report alone does not make it wait.
        let working = session(.working, companion: reported)
        #expect(!working.needsHuman && working.questions.isEmpty && working.needs == nil)
    }

    @Test func theStoreAttachesReportsToTheSessionsOnItsListOnly() async throws {
        let hub = CompanionHub(now: { start })
        hub.receive(body(["kind": "question", "questions": [question("Apple or pear?", ["apple", "pear"])]]))
        hub.receive(body(["kind": "turn.start", "session": "99999999-0000-4000-8000-000000000000"]))
        let listed = [
            SessionSummary(id: "22222222", sessionId: conversation.uppercased(), name: "asks", state: .blocked),
            SessionSummary(id: "33333333", sessionId: "33333333-0000-4000-8000-000000000000", name: "plain", state: .working),
            SessionSummary(id: "44444444", name: "no conversation id", state: .done),
        ]
        let store = SessionStore(fetch: { AgentsSnapshot(sessions: listed, skipped: 0) }, companion: { hub.snapshot() }, now: { start })
        await store.refresh()
        let sessions = await store.snapshot.sessions
        #expect(sessions.map(\.id) == ["22222222", "33333333", "44444444"])
        #expect(sessions[0].questions.map(\.question) == ["Apple or pear?"])
        #expect(sessions[1].companion == nil && sessions[2].companion == nil)

        // Without a hub the store is what it was.
        let plain = SessionStore(fetch: { AgentsSnapshot(sessions: listed, skipped: 0) }, now: { start })
        await plain.refresh()
        #expect(await plain.snapshot.sessions.allSatisfy { $0.companion == nil })
    }
}
