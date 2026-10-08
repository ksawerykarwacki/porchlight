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
        #expect(row.options == ["greeting.txt (Recommended)", "salute.txt"])
        #expect(row.suggestedReply == nil)
        #expect(row.age == "waiting 1m")
    }

    @Test func anApprovalShowsTheToolTheCommandAndTheWorktree() throws {
        let row = try #require(try rows()["55555555"])
        #expect(row.kind == .approval)
        #expect(row.tool == "Bash")
        #expect(row.detail == #"echo hi > hello.txt && git add hello.txt && git commit -q -m "add hello""#)
        #expect(row.place == "probe · add-hello")
        #expect(row.options.isEmpty)
    }

    @Test func freeTextNeedsKeepTheSuggestedReply() throws {
        let row = try #require(try rows()["11111111"])
        #expect(row.kind == .waiting)
        #expect(row.detail == "Which of the two timeouts should I raise?")
        #expect(row.suggestedReply == "Raise the network timeout to 30s.")
        #expect(row.age == "waiting 1d")
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
}
