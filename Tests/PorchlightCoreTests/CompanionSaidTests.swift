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

/// A session as the store would hand it on after these reports, with Claude Code's own fragment
/// of the last reply in its state file.
private func session(_ reports: [[String: Any]], state: SessionState = .blocked) throws -> Session {
    let hub = CompanionHub(now: { start })
    reports.forEach { hub.receive(report($0)) }
    let job = try JSONDecoder().decode(JobState.self, from: Data(#"{"state":"blocked","name":"n","needs":"which one."}"#.utf8))
    return Session(summary: SessionSummary(id: "22222222", sessionId: conversation, name: "n", state: state), job: job, companion: hub.snapshot()[conversation])
}

@Suite struct CompanionSaidTests {
    let said = "Layer 3 is confirmed in the installed app.\n\nThe next work is layers 4 to 6. I'll start when you say which one."

    @Test func theEndOfATurnCarriesTheEndOfWhatWasSaid() throws {
        let event = try #require(CompanionEvent.decode(report(["kind": "turn.complete", "reason": "answer", "said": "  \(said)\n"]), receivedAt: start))
        #expect(event.kind == .turnComplete(reason: "answer") && event.said == said)
        // What a person reads of an event, and so what `porchlight companion` prints, has none of it.
        #expect(event.line == "22222222  turn finished (answer)")

        // Nothing said, or not text: none. A long one keeps its end.
        #expect(CompanionEvent.decode(report(["kind": "turn.complete", "said": "  "]), receivedAt: start)?.said == nil)
        #expect(CompanionEvent.decode(report(["kind": "turn.complete"]), receivedAt: start)?.said == nil)
        let long = try #require(CompanionEvent.decode(report(["kind": "turn.complete", "said": String(repeating: "a", count: 5000) + " which one?"]), receivedAt: start))
        #expect(long.said?.count == CompanionEvent.saidLimit && long.said?.hasSuffix("which one?") == true)
        // Only a turn's end has it.
        #expect(CompanionEvent.decode(report(["kind": "turn.start", "said": "x"]), receivedAt: start)?.said == nil)
    }

    @Test func aWaitingSessionShowsWhatItSaidUntilItsNextTurn() throws {
        let waiting = try session([["kind": "turn.start"], ["kind": "turn.complete", "reason": "answer", "said": said]])
        #expect(waiting.lastSaid == said)
        let row = InboxRow(session: waiting, now: start)
        #expect(row.kind == .waiting && row.said == said && row.saidEnding == said && row.context == nil)
        // The one line, for the palette and notifications, is still Claude Code's.
        #expect(row.detail == "which one.")

        // A new turn, a turn that said nothing, or the session's end take it away.
        #expect(try session([["kind": "turn.complete", "said": said], ["kind": "turn.start"]]).lastSaid == nil)
        #expect(try session([["kind": "turn.complete", "said": said], ["kind": "turn.start"], ["kind": "turn.complete", "reason": "aborted"]]).lastSaid == nil)
        #expect(try session([["kind": "turn.complete", "said": said], ["kind": "session.end"]]).lastSaid == nil)
        // Not while the session is not waiting, and not beside a question or an approval of its own.
        #expect(try session([["kind": "turn.complete", "said": said]], state: .working).lastSaid == nil)
        let asking = try session([["kind": "turn.complete", "said": said], ["kind": "permission", "tool": "Bash", "detail": "make"]])
        #expect(asking.lastSaid == nil && InboxRow(session: asking, now: start).said == nil)
        // Without the mod there is only the fragment.
        let plain = InboxRow(session: Session(summary: SessionSummary(id: "a", name: "n", state: .blocked)), now: start)
        #expect(plain.said == nil && plain.saidEnding == nil)
    }

    @Test func theEndingIsTheLastParagraphsThatFit() {
        #expect(InboxRow.ending(of: "One.\n\nTwo.\n\nThree.") == "One.\n\nTwo.\n\nThree.")
        let long = String(repeating: "word ", count: 80).trimmingCharacters(in: .whitespaces)
        // The last paragraph whole, and the one before only if both fit.
        #expect(InboxRow.ending(of: "\(long)\n\nShall I merge?") == "… Shall I merge?")
        #expect(InboxRow.ending(of: "\(long)\n\nShort one.\n\nShall I merge?") == "… Short one.\n\nShall I merge?")
        // A last paragraph too long on its own is cut from the front, at a word.
        let cut = InboxRow.ending(of: long + " and the question?", limit: 60)
        #expect(cut.hasPrefix("…word ") && cut.hasSuffix("and the question?") && cut.count <= 61)
        #expect(InboxRow.ending(of: " \n\n ") == "")
        // A row whose reply is longer than its ending offers the rest.
        let row = try? InboxRow(session: session([["kind": "turn.complete", "said": "\(long)\n\nShall I merge?"]]), now: start)
        #expect(row?.saidEnding == "… Shall I merge?" && row?.said != row?.saidEnding)
    }
}
