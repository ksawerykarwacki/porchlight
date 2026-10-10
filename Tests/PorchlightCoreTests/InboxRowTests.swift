import Foundation
import Testing

@testable import PorchlightCore

@Suite struct InboxRowTests {
    // Shortly after the fixtures' timestamps.
    let now = Date(timeIntervalSince1970: 1_791_480_200)

    func rows() throws -> [String: InboxRow] {
        let summaries = try AgentsCLISource.decode(Fixtures.text("agents-all.json")).sessions
        let sessions = JobStateSource(jobsDirectory: Fixtures.jobs).enrich(summaries)
        return Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, InboxRow(session: $0, now: now)) })
    }

    @Test func aQuestionShowsItsTextAndOptionsWithoutRepeatingThem() throws {
        let row = try #require(try rows()["22222222"])
        #expect(row.kind == .question)
        #expect(row.title == "rename the file")
        #expect(row.place == "beta")
        #expect(row.detail == "Should hello.txt be renamed to greeting.txt or salute.txt?")
        #expect(row.options == ["greeting.txt", "salute.txt"])
        #expect(row.recommendedOption == 0)
        #expect(row.repo == "beta" && row.worktree == nil)
        #expect(!row.isOverdue)
        #expect(row.suggestedReply == nil)
        #expect(row.age == "waiting 1m")
    }

    @Test func anApprovalShowsTheToolTheCommandAndTheWorktree() throws {
        let row = try #require(try rows()["55555555"])
        #expect(row.kind == .approval)
        #expect(row.tool == "Bash")
        #expect(row.detail == #"echo hi > hello.txt && git add hello.txt && git commit -q -m "add hello""#)
        #expect(row.place == "probe / add-hello")
        #expect(row.repo == "probe" && row.worktree == "add-hello")
        #expect(row.recommendedOption == nil)
        #expect(row.options.isEmpty)
    }

    @Test func freeTextNeedsKeepTheSuggestedReply() throws {
        let row = try #require(try rows()["11111111"])
        #expect(row.kind == .waiting)
        #expect(row.detail == "Which of the two timeouts should I raise?")
        #expect(row.suggestedReply == "Raise the network timeout to 30s.")
        #expect(row.age == "waiting 1d")
        #expect(row.isOverdue)
    }

    @Test func aWaitingRowSaysWhereTheSessionStandsBesideWhatItAsks() throws {
        // What the last turn came to, from the state file's `output.result`.
        #expect(try rows()["11111111"]?.context == "Found two candidate timeouts.")
        // A question with options and an approval have none in these files (`output` is null).
        #expect(try rows()["22222222"]?.context == nil && rows()["55555555"]?.context == nil)

        func row(_ fields: [String: Any], state: SessionState = .blocked) throws -> InboxRow {
            var json: [String: Any] = ["state": "blocked", "name": "n", "needs": "which one."]
            fields.forEach { json[$0] = $1 }
            let job = try JSONDecoder().decode(JobState.self, from: JSONSerialization.data(withJSONObject: json))
            return InboxRow(session: Session(summary: SessionSummary(id: "a", name: "n", state: state), job: job), now: Date())
        }
        // Without a result the status line serves; an odd `output` is passed over, not fatal.
        #expect(try row(["detail": "layer 3 confirmed; layers 4 to 6 next"]).context == "layer 3 confirmed; layers 4 to 6 next")
        #expect(try row(["detail": "status", "output": "text"]).context == "status")
        #expect(try row(["detail": "status", "output": ["result": ""]]).context == "status")
        #expect(try row(["output": ["result": "Line one\nline two"]]).context == "Line one line two")
        // Said once, and only while the session waits; never for an approval.
        #expect(try row(["output": ["result": "Which one."]]).context == nil)
        #expect(try row([:]).context == nil)
        #expect(try row(["output": ["result": "Done."]], state: .working).context == nil)
        #expect(try row(["needs": "approve Bash: make", "output": ["result": "Ready to build."]]).context == nil)
    }

    @Test func sessionsThatAreNotBlockedShowNoQuestion() throws {
        let rows = try rows()
        let working = try #require(rows["33333333"])
        #expect(working.kind == .working)
        #expect(working.detail == nil)
        #expect(working.age == "started 9m ago")
        let done = try #require(rows["44444444"])
        #expect(done.kind == .done)
        #expect(done.age == "5m ago")
        let odd = try #require(rows["66666666"])
        #expect(odd.kind == .unknown)
        #expect(odd.detail == "state: hibernating")
    }

    @Test func blockedWithoutJobDetailsFallsBackToTheCLIsCategory() {
        let prompt = Session(summary: SessionSummary(id: "a", name: "n", cwd: "/x/repo", state: .blocked, waitingFor: "permission prompt"))
        #expect(InboxRow(session: prompt, now: now).kind == .approval)
        #expect(InboxRow(session: prompt, now: now).detail == nil)
        #expect(InboxRow(session: prompt, now: now).age == nil)
        let plain = Session(summary: SessionSummary(id: "b", name: "n", cwd: "/x/repo", state: .blocked))
        #expect(InboxRow(session: plain, now: now).kind == .waiting)
    }

    @Test func collapsesMultiLineDetailToOneLine() {
        #expect(InboxRow.singleLine("first line\n\n  second\tline ") == "first line second line")
    }

    @Test func sectionsFollowTheGroupOrderAndSkipEmptyOnes() throws {
        let summaries = try AgentsCLISource.decode(Fixtures.text("agents-all.json")).sessions
        let sessions = JobStateSource(jobsDirectory: Fixtures.jobs).enrich(summaries)
        let sections = InboxGroups(sessions: sessions, now: now).sections(now: now)
        #expect(sections.map(\.title) == ["Needs you", "Working", "Recently done", "Other"])
        #expect(sections[0].rows.map(\.id) == ["11111111", "55555555", "22222222"])
        #expect(InboxGroups(sessions: [], now: now).sections(now: now).isEmpty)
    }

    @Test func describesAStaleSnapshotInOneSentence() {
        var snapshot = StoreSnapshot()
        #expect(snapshot.staleNotice(now: now) == nil)
        snapshot.problem = .claudeNotFound(candidates: [])
        #expect(snapshot.staleNotice(now: now) == "The claude command was not found.")
        snapshot.problem = .timedOut
        snapshot.fetchedAt = now - 180
        #expect(snapshot.staleNotice(now: now) == "The claude command did not answer in time. Showing sessions from 3m ago.")
        snapshot.fetchedAt = now - 5
        #expect(snapshot.staleNotice(now: now) == "The claude command did not answer in time. Showing sessions from a moment ago.")
    }

    @Test func theMenuBarStatusTellsIdleWaitingAndOverdueApart() {
        func blocked(_ id: String, waited: TimeInterval?) -> Session {
            Session(summary: SessionSummary(id: id, name: id, cwd: "/x/\(id)", state: .blocked), observedBlockedSince: waited.map { now - $0 })
        }
        var snapshot = StoreSnapshot()
        #expect(MenuBarStatus(snapshot: snapshot, now: now) == .idle)

        snapshot.sessions = [Session(summary: SessionSummary(id: "w", name: "w", cwd: "/x/w", state: .working))]
        #expect(MenuBarStatus(snapshot: snapshot, now: now) == .idle)

        snapshot.sessions += [blocked("a", waited: 60), blocked("b", waited: 7199)]
        #expect(MenuBarStatus(snapshot: snapshot, now: now) == .waiting(count: 2))

        snapshot.sessions.append(blocked("c", waited: 7200))
        #expect(MenuBarStatus(snapshot: snapshot, now: now) == .overdue(count: 3))
        #expect(MenuBarStatus(snapshot: snapshot, overdueAfter: 86_400, now: now) == .waiting(count: 3))

        // Snoozed sessions neither count nor light the lantern; an expired snooze counts again.
        let snoozes: [String: Snooze] = ["c": .until(now + 3600), "a": .until(now - 1), "b": .untilChange(waitingSince: now - 7199)]
        #expect(MenuBarStatus(snapshot: snapshot, snoozes: snoozes, now: now) == .waiting(count: 1))
        #expect(MenuBarStatus(snapshot: snapshot, snoozes: ["a": .until(now + 1), "b": .until(now + 1), "c": .until(now + 1)], now: now) == .idle)
        let snoozedRow = InboxRow(session: blocked("c", waited: 7200), snooze: .until(now + 3600), now: now)
        #expect(snoozedRow.isSnoozed && snoozedRow.age == "snoozed, waiting 2h")
        #expect(!InboxRow(session: blocked("c", waited: 7200), snooze: .until(now - 1), now: now).isSnoozed)
        // A snooze kept for a session that has since started working means nothing.
        let working = Session(summary: SessionSummary(id: "w", name: "w", cwd: "/x/w", state: .working))
        #expect(!InboxRow(session: working, snooze: .until(now + 3600), now: now).isSnoozed)

        // A wait of unknown length is waiting, never overdue.
        snapshot.sessions = [blocked("d", waited: nil)]
        #expect(MenuBarStatus(snapshot: snapshot, now: now) == .waiting(count: 1))
        #expect(MenuBarStatus.idle.count == 0)
        // The number appears from two up; one waiting session is just a lit lantern.
        #expect(MenuBarStatus.idle.badge == nil)
        #expect(MenuBarStatus.waiting(count: 1).badge == nil)
        #expect(MenuBarStatus.overdue(count: 1).badge == nil)
        #expect(MenuBarStatus.waiting(count: 2).badge == "2")
        #expect(MenuBarStatus.overdue(count: 12).badge == "12")
        #expect(MenuBarStatus.overdue(count: 3).count == 3)
        #expect(MenuBarStatus.waiting(count: 1).summary == "1 session is waiting on you")
        #expect(MenuBarStatus.overdue(count: 2).summary == "2 sessions are waiting on you, at least one for a long time")
    }
}
