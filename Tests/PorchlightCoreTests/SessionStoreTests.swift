import Foundation
import Testing

@testable import PorchlightCore

/// A scripted stand-in for the CLI: hands out queued results and counts the calls.
actor ScriptedFetch {
    private var results: [Result<AgentsSnapshot, Error>]
    private(set) var calls = 0
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNext = false

    init(_ results: [Result<AgentsSnapshot, Error>]) { self.results = results }

    func holdNextCall() { holdNext = true }

    func release() {
        gate?.resume()
        gate = nil
    }

    func next() async throws -> AgentsSnapshot {
        calls += 1
        if holdNext {
            holdNext = false
            await withCheckedContinuation { gate = $0 }
        }
        return try results.removeFirst().get()
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value += seconds
        lock.unlock()
    }
}

func summary(_ id: String, _ state: SessionState, name: String? = nil, startedAt: Date? = nil) -> SessionSummary {
    SessionSummary(id: id, name: name ?? "session \(id)", cwd: "/Users/u/code/\(id)", state: state, startedAt: startedAt)
}

func agents(_ sessions: SessionSummary...) -> Result<AgentsSnapshot, Error> {
    .success(AgentsSnapshot(sessions: sessions, skipped: 0))
}

@Suite struct SessionStoreTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    func scratchFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("nested/blocked-since.json")
    }

    @Test func keepsTheLastGoodSnapshotAndMarksItStaleWhenTheCLIFails() async {
        let script = ScriptedFetch([
            agents(summary("a", .blocked), summary("b", .working)),
            .failure(AgentsCLIError.failed(exitCode: 3, stderr: "daemon unavailable")),
            .failure(CLIError.timedOut(after: 15)),
            agents(summary("a", .working)),
        ])
        let clock = Clock(start)
        let store = SessionStore(fetch: { try await script.next() }, now: { clock.now })

        await store.refresh()
        var snapshot = await store.snapshot
        #expect(snapshot.sessions.map(\.id) == ["a", "b"])
        #expect(!snapshot.isStale)
        #expect(snapshot.fetchedAt == start)

        clock.advance(10)
        let events = await store.refresh()
        snapshot = await store.snapshot
        #expect(events.isEmpty)
        #expect(snapshot.sessions.map(\.id) == ["a", "b"])
        #expect(snapshot.problem == .cliFailed(exitCode: 3, stderr: "daemon unavailable"))
        #expect(snapshot.fetchedAt == start)
        #expect(snapshot.waitingCount == 1)

        await store.refresh()
        #expect(await store.snapshot.problem == .timedOut)

        clock.advance(10)
        await store.refresh()
        snapshot = await store.snapshot
        #expect(snapshot.problem == nil)
        #expect(snapshot.sessions.map(\.id) == ["a"])
        #expect(snapshot.fetchedAt == start + 20)
    }

    @Test func blockedSinceSurvivesARestartAndResetsAfterUnblocking() async throws {
        let file = try scratchFile()
        let clock = Clock(start)

        let first = ScriptedFetch([agents(summary("a", .blocked)), agents(summary("a", .blocked))])
        let storeA = SessionStore(fetch: { try await first.next() }, blockedSinceFile: file, now: { clock.now })
        await storeA.refresh()
        clock.advance(600)
        await storeA.refresh()
        #expect(await storeA.snapshot.sessions.first?.waitingSince == start)

        // A new process: nothing in memory, only the file.
        clock.advance(3000)
        let second = ScriptedFetch([agents(summary("a", .blocked)), agents(summary("a", .working)), agents(summary("a", .blocked))])
        let storeB = SessionStore(fetch: { try await second.next() }, blockedSinceFile: file, now: { clock.now })
        await storeB.refresh()
        #expect(await storeB.snapshot.sessions.first?.waitingSince == start)

        await storeB.refresh()
        #expect(await storeB.snapshot.sessions.first?.waitingSince == nil)

        clock.advance(60)
        await storeB.refresh()
        #expect(await storeB.snapshot.sessions.first?.waitingSince == start + 3660)
    }

    @Test func prefersTheJobFilesTimestampOverItsOwnObservation() async throws {
        let summaries = try AgentsCLISource.decode(Fixtures.text("agents-all.json"))
        let jobs = JobStateSource(jobsDirectory: Fixtures.jobs)
        let store = SessionStore(fetch: { summaries }, enrich: { jobs.enrich($0) }, now: { Date(timeIntervalSince1970: 1_900_000_000) })
        await store.refresh()
        let sessions = await store.snapshot.sessions
        let enriched = try #require(sessions.first { $0.id == "55555555" })
        #expect(enriched.waitingSince == enriched.job?.updatedAt)
        #expect(enriched.observedBlockedSince == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(await store.snapshot.skippedRows == 2)
    }

    @Test func reportsWhatChangedBetweenReads() async {
        let script = ScriptedFetch([
            agents(summary("a", .working), summary("b", .blocked)),
            agents(summary("a", .blocked), summary("b", .working), summary("c", .done)),
            agents(summary("a", .blocked, name: "renamed"), summary("b", .working)),
            agents(summary("a", .blocked, name: "renamed"), summary("b", .working)),
        ])
        let store = SessionStore(fetch: { try await script.next() }, now: { Date(timeIntervalSince1970: 1_800_000_000) })

        func names(_ events: [SessionEvent]) -> [String] {
            events.map { event in
                switch event {
                case .appeared(let s): "appeared \(s.id)"
                case .becameBlocked(let s): "blocked \(s.id)"
                case .unblocked(let s): "unblocked \(s.id)"
                case .changed(let s): "changed \(s.id)"
                case .removed(let id): "removed \(id)"
                }
            }
        }

        #expect(names(await store.refresh()) == ["appeared a", "appeared b", "blocked b"])
        #expect(names(await store.refresh()) == ["blocked a", "unblocked b", "appeared c"])
        #expect(names(await store.refresh()) == ["changed a", "removed c"])
        #expect(names(await store.refresh()) == [])
    }

    @Test func neverRunsTwoReadsAtOnceButReadsAgainAfterAnOverlap() async {
        let script = ScriptedFetch([agents(summary("a", .working)), agents(summary("a", .blocked))])
        await script.holdNextCall()
        let store = SessionStore(fetch: { try await script.next() })

        let running = Task { await store.refresh() }
        while await script.calls == 0 { await Task.yield() }

        // Arrives mid-read: returns at once without starting a second read.
        let overlapping = await store.refresh()
        #expect(overlapping.isEmpty)
        #expect(await script.calls == 1)
        _ = await store.refresh()
        #expect(await script.calls == 1)

        // The running read then reads exactly once more, picking up what changed meanwhile.
        await script.release()
        let events = await running.value
        #expect(await script.calls == 2)
        #expect(events.count == 2)
        #expect(await store.snapshot.waitingCount == 1)
    }

    @Test func publishesEveryRefreshToObservers() async {
        let script = ScriptedFetch([agents(summary("a", .blocked)), .failure(AgentsCLIError.invalidJSON)])
        let store = SessionStore(fetch: { try await script.next() })
        var updates = await store.updates().makeAsyncIterator()

        await store.refresh()
        await store.refresh()
        let first = await updates.next()
        let second = await updates.next()
        #expect(first?.events.count == 2)
        #expect(first?.snapshot.isStale == false)
        #expect(second?.events.isEmpty == true)
        #expect(second?.snapshot.problem == .invalidOutput)
    }

    @Test func reportsAMissingCLIAsAProblem() async {
        let locator = ClaudeLocator(environment: [:], homeDirectory: "/nonexistent", isExecutable: { _ in false })
        let store = SessionStore.live(locator: locator, stateDirectory: FileManager.default.temporaryDirectory)
        await store.refresh()
        guard case .claudeNotFound(let candidates) = await store.snapshot.problem else {
            Issue.record("expected claudeNotFound")
            return
        }
        #expect(candidates.contains("/nonexistent/.local/bin/claude"))
    }
}

@Suite struct InboxGroupsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ id: String, _ state: SessionState, waited: TimeInterval? = nil, started: TimeInterval? = nil) -> Session {
        Session(
            summary: summary(id, state, startedAt: started.map { now - $0 }),
            observedBlockedSince: waited.map { now - $0 })
    }

    @Test func ordersEachGroupAsTheInboxShowsIt() {
        let groups = InboxGroups(sessions: [
            session("short-wait", .blocked, waited: 60),
            session("unknown-wait", .blocked),
            session("long-wait", .blocked, waited: 86_400 * 21),
            session("new-work", .working, started: 30),
            session("old-work", .working, started: 7200),
            session("done-recent", .done, started: 600),
            session("done-older", .done, started: 3600 * 5),
            session("done-stale", .done, started: 3600 * 30),
            session("odd", .unknown("hibernating")),
        ], now: now)

        #expect(groups.needsYou.map(\.id) == ["long-wait", "short-wait", "unknown-wait"])
        #expect(groups.working.map(\.id) == ["old-work", "new-work"])
        #expect(groups.recentlyDone.map(\.id) == ["done-recent", "done-older"])
        #expect(groups.other.map(\.id) == ["odd"])
        #expect(!groups.isEmpty)
    }

    @Test func theRecentWindowIsConfigurable() {
        let sessions = [session("a", .done, started: 3600 * 2), session("b", .done, started: 3600 * 30)]
        #expect(InboxGroups(sessions: sessions, now: now, recentWindow: 3600).recentlyDone.isEmpty)
        #expect(InboxGroups(sessions: sessions, now: now, recentWindow: 3600 * 48).recentlyDone.map(\.id) == ["a", "b"])
        #expect(InboxGroups(sessions: [], now: now).isEmpty)
    }

    @Test func formatsAgesCompactly() {
        #expect(Age.short(since: nil, now: now) == nil)
        #expect(Age.short(since: now - 5, now: now) == "just now")
        #expect(Age.short(since: now - 125, now: now) == "2m")
        #expect(Age.short(since: now - 3 * 3600 - 10, now: now) == "3h")
        #expect(Age.short(since: now - 21 * 86_400, now: now) == "21d")
        #expect(Age.short(since: now + 50, now: now) == "just now")
    }
}
