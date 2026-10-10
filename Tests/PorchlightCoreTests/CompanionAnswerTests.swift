import Foundation
import Testing

@testable import PorchlightCore

private let conversation = "22222222-0000-4000-8000-000000000000"
private let start = Date(timeIntervalSince1970: 1_791_540_000)

private func question(_ text: String, _ options: [String], multiSelect: Bool = false) -> [String: Any] {
    ["question": text, "multiSelect": multiSelect, "options": options.map { ["label": $0] }]
}

private func report(_ fields: [String: Any]) -> Data {
    var all: [String: Any] = ["v": 1, "session": conversation, "kind": "question"]
    fields.forEach { all[$0] = $1 }
    return try! JSONSerialization.data(withJSONObject: all)
}

/// A waiting session as the store would hand it on after these reports.
private func session(_ reports: [[String: Any]], state: SessionState = .blocked) -> Session {
    let hub = CompanionHub(now: { start })
    reports.forEach { hub.receive(report($0)) }
    return Session(
        summary: SessionSummary(id: "22222222", sessionId: conversation.uppercased(), name: "asks", state: state), companion: hub.snapshot()[conversation])
}

@Suite struct CompanionAnswerTests {
    let fruit = question("Apple or pear?", ["apple (Recommended)", "pear"])

    @Test func aQuestionReportCarriesItsIdAndWhetherAnAnswerIsTaken() throws {
        let event = try #require(CompanionEvent.decode(report(["id": "q3-1791540000000", "can": ["answer", "something-newer"], "questions": [fruit]]), receivedAt: start))
        #expect(event.questionID == "q3-1791540000000" && event.takesAnswer)
        // No word about answering, an id that is not one, or a report of another kind: not answerable.
        #expect(CompanionEvent.decode(report(["id": "q3-1", "questions": [fruit]]), receivedAt: start)?.takesAnswer == false)
        #expect(CompanionEvent.decode(report(["id": "q3-1", "can": "answer", "questions": [fruit]]), receivedAt: start)?.takesAnswer == false)
        for bad in ["", "has space", "../x", String(repeating: "q", count: 65)] {
            let odd = try #require(CompanionEvent.decode(report(["id": bad, "can": ["answer"], "questions": [fruit]]), receivedAt: start))
            #expect(odd.questionID == nil && !odd.takesAnswer)
        }
        let other = try #require(CompanionEvent.decode(report(["kind": "permission", "tool": "Bash", "id": "q1-1", "can": ["answer"]]), receivedAt: start))
        #expect(other.questionID == nil && !other.takesAnswer)
        #expect(try JSONDecoder().decode(JobState.Question.self, from: JSONSerialization.data(withJSONObject: question("x", ["a"], multiSelect: true))).multiSelect)
        #expect(try !JSONDecoder().decode(JobState.Question.self, from: Data(#"{"question":"x"}"#.utf8)).multiSelect)
    }

    @Test func onlyOneSingleChoiceQuestionFromAModThatTakesAnswersIsAnswerable() throws {
        let target = try #require(session([["id": "q1-5", "can": ["answer"], "questions": [fruit]]]).answerTarget)
        #expect(target == AnswerTarget(sessionID: conversation, questionID: "q1-5", question: "Apple or pear?", options: ["apple (Recommended)", "pear"]))

        // An older mod, several questions, a choice of several, no options, or a session not waiting.
        #expect(session([["id": "q1-5", "questions": [fruit]]]).answerTarget == nil)
        #expect(session([["id": "q1-5", "can": ["answer"], "questions": [fruit, question("Tea or coffee?", ["tea", "coffee"])]]]).answerTarget == nil)
        #expect(session([["id": "q1-5", "can": ["answer"], "questions": [question("Which?", ["a", "b"], multiSelect: true)]]]).answerTarget == nil)
        #expect(session([["id": "q1-5", "can": ["answer"], "questions": [question("Say more?", [])]]]).answerTarget == nil)
        #expect(session([["id": "q1-5", "can": ["answer"], "questions": [fruit]]], state: .working).answerTarget == nil)
        #expect(Session(summary: SessionSummary(id: "a", sessionId: conversation, name: "n", state: .blocked)).answerTarget == nil)

        // Once the question is answered, or the turn moves on, or an approval takes its place: no longer.
        for after in [["kind": "resumed"], ["kind": "turn.complete"], ["kind": "turn.start"], ["kind": "permission", "tool": "Bash", "detail": "make"]] as [[String: Any]] {
            #expect(session([["id": "q1-5", "can": ["answer"], "questions": [fruit]], after]).answerTarget == nil)
        }
        // A new asking has its own id.
        #expect(session([["id": "q1-5", "can": ["answer"], "questions": [fruit]], ["id": "q2-9", "can": ["answer"], "questions": [fruit]]]).answerTarget?.questionID == "q2-9")
    }

    @Test func whatTheRowShowsIsWhatWouldBeAnswered() throws {
        // The state file is clearly later than the report, so the row shows the file's question:
        // the report's question is not the one on screen and must not be answered.
        let json: [String: Any] = [
            "state": "blocked", "name": "task", "needs": "answer: A later question?",
            "updatedAt": ISO8601DateFormatter().string(from: start + 60),
            "block": ["questions": [question("A later question?", ["yes", "no"])]],
        ]
        let job = try JSONDecoder().decode(JobState.self, from: JSONSerialization.data(withJSONObject: json))
        let hub = CompanionHub(now: { start })
        hub.receive(report(["id": "q1-5", "can": ["answer"], "questions": [fruit]]))
        let later = Session(summary: SessionSummary(id: "22222222", sessionId: conversation, name: "asks", state: .blocked), job: job, companion: hub.snapshot()[conversation])
        #expect(later.questions.map(\.question) == ["A later question?"] && later.answerTarget == nil)
        #expect(!InboxRow(session: later, now: start).isAnswerable)

        let shown = session([["id": "q1-5", "can": ["answer"], "questions": [fruit]]])
        let row = InboxRow(session: shown, now: start)
        // The row cleans the label for the eye; the answer is the label as the session wrote it.
        #expect(row.answerID == "q1-5" && row.options == ["apple", "pear"] && row.recommendedOption == 0)
        #expect(shown.answerTarget?.options == ["apple (Recommended)", "pear"])
    }

    @Test func anAnswerNamesTheAskingAndOneOfItsOwnOptions() throws {
        let target = AnswerTarget(sessionID: conversation, questionID: "q1-5", question: "Apple or pear?", options: ["apple (Recommended)", "pear"])
        let command = try #require(target.command(choosing: 1))
        let sent = try #require(JSONSerialization.jsonObject(with: command) as? [String: Any])
        #expect(sent["type"] as? String == "answer" && sent["id"] as? String == "q1-5" && sent["v"] as? Int == 1)
        #expect(sent["answers"] as? [String: String] == ["Apple or pear?": "pear"])
        #expect(sent.count == 4)
        let firstCommand = try #require(target.command(choosing: 0))
        let first = try #require(JSONSerialization.jsonObject(with: firstCommand) as? [String: Any])
        #expect(first["answers"] as? [String: String] == ["Apple or pear?": "apple (Recommended)"])
        // No option there: no command at all.
        #expect(target.command(choosing: 2) == nil && target.command(choosing: -1) == nil)
    }
}
