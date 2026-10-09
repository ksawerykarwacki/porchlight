import Foundation
import Testing

@testable import PorchlightCore

@Suite struct TriageVerdictTests {
    let now = Date(timeIntervalSince1970: 1_791_540_000)
    let day: TimeInterval = 86400

    func session(_ state: String, idle: TimeInterval, kind: String? = "background", waited: TimeInterval? = nil) -> Session {
        Session(
            summary: SessionSummary(id: "s-\(state)", name: "task", cwd: "/Users/u/code/app", kind: kind, state: SessionState(rawValue: state), startedAt: now - idle),
            observedBlockedSince: waited.map { now - $0 })
    }

    func verdict(_ session: Session, worktree: WorktreeReport? = nil, unreadable: Bool = false, pr: PullRequestState = .none, branch: String? = nil) -> TriageItem {
        Triage.verdict(for: TriageFacts(session: session, worktree: worktree, worktreeUnreadable: unreadable, pullRequest: pr, branch: branch), now: now)
    }

    func worktree(uncommitted: Int = 0, unpushed: Int? = 0) -> WorktreeReport {
        WorktreeReport(name: "fix", path: "/Users/u/code/app/.claude/worktrees/fix", uncommitted: uncommitted, unpushed: unpushed)
    }

    @Test func aFinishedSessionWithNothingToLoseIsSafe() {
        let done = session("done", idle: 3 * day)
        let plain = verdict(done)
        #expect(plain.verdict == .safeToRemove && plain.reason == "no worktree")
        let merged = verdict(done, worktree: worktree(), pr: .merged(number: 12), branch: "fix")
        #expect(merged.verdict == .safeToRemove && merged.reason == "worktree clean, PR #12 is merged")
        #expect(verdict(done, worktree: worktree(), pr: .closed(number: 5), branch: "fix").verdict == .safeToRemove)
        // The pull request could not be looked up: said, and not a reason to keep local nothing.
        let unknown = verdict(done, worktree: worktree(), pr: .unknown, branch: "fix")
        #expect(unknown.verdict == .safeToRemove && unknown.reason.contains("could not be checked"))
    }

    @Test func workThatExistsNowhereElseNeedsADecisionWhateverElseIsTrue() {
        let done = session("done", idle: 30 * day)
        let dirty = verdict(done, worktree: worktree(uncommitted: 2), pr: .merged(number: 12), branch: "fix")
        #expect(dirty.verdict == .needsDecision && dirty.reason == "2 uncommitted files, PR #12 is merged")
        let unpushed = verdict(done, worktree: worktree(unpushed: 1))
        #expect(unpushed.verdict == .needsDecision && unpushed.reason == "1 commit on no remote")
        // Even with an open pull request, and even when it is only waiting.
        #expect(verdict(done, worktree: worktree(uncommitted: 1, unpushed: 3), pr: .open(number: 3), branch: "fix").verdict == .needsDecision)
        #expect(verdict(session("blocked", idle: 30 * day, waited: 30 * day), worktree: worktree(uncommitted: 1)).verdict == .needsDecision)
    }

    @Test func aWorktreeThatCouldNotBeCheckedIsNeverSafe() {
        let done = session("done", idle: 3 * day)
        let unreadable = verdict(done, unreadable: true)
        #expect(unreadable.verdict == .needsDecision && unreadable.reason == "its worktree could not be checked")
        // Read, but whether its commits are pushed could not be worked out.
        #expect(verdict(done, worktree: worktree(unpushed: nil)).verdict == .needsDecision)
    }

    @Test func anOpenPullRequestMeansKeep() {
        let item = verdict(session("done", idle: 3 * day), worktree: worktree(), pr: .open(number: 34), branch: "fix")
        #expect(item.verdict == .keep && item.reason == "PR #34 is open")
    }

    @Test func aLongWaitIsStaleAndSoIsALongStop() {
        let waiting = verdict(session("blocked", idle: 20 * day, waited: 14 * day))
        #expect(waiting.verdict == .stale && waiting.reason == "waiting for 14d")
        let stopped = verdict(session("stopped", idle: 10 * day))
        #expect(stopped.verdict == .stale && stopped.reason.hasPrefix("stopped for a long time"))
        // Stopped or failed a few days ago: nothing to lose, so it can go.
        #expect(verdict(session("failed", idle: 2 * day)).verdict == .safeToRemove)
    }

    @Test func onlySessionsThatAreNotMovingAndNotKeptAreListed() {
        let settings = TriageSettings()
        func listed(_ session: Session, pins: Pins = Pins()) -> Bool { Triage.isCandidate(session, pins: pins, settings: settings, now: now) }
        #expect(listed(session("done", idle: 2 * day)))
        #expect(listed(session("stopped", idle: 2 * day)))
        #expect(listed(session("blocked", idle: 9 * day, waited: 8 * day)))
        // Finished an hour ago, or waiting since yesterday: not yet something to clear.
        #expect(!listed(session("done", idle: 3600)))
        #expect(!listed(session("blocked", idle: 2 * day, waited: day)))
        #expect(!listed(session("working", idle: 30 * day)))
        // In a terminal of its own, or of unknown kind: not removable from here.
        #expect(!listed(session("done", idle: 30 * day, kind: "interactive")))
        #expect(!listed(session("done", idle: 30 * day, kind: nil)))
        var pins = Pins()
        pins.pin("s-done", now: now)
        #expect(!listed(session("done", idle: 30 * day), pins: pins))
    }

    @Test func theListIsOrderedByWhatCanGoFirst() {
        let items = [
            verdict(session("done", idle: 3 * day), worktree: worktree(), pr: .open(number: 1), branch: "b"),
            verdict(session("blocked", idle: 20 * day, waited: 14 * day)),
            verdict(session("done", idle: 3 * day), worktree: worktree(uncommitted: 1)),
            verdict(session("done", idle: 3 * day)),
        ]
        #expect(Triage.sorted(items).map(\.verdict) == [.safeToRemove, .needsDecision, .stale, .keep])
    }

    @Test func settingsAreReadTolerantly() throws {
        func load(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        #expect(try load(#"{"triage": {"staleAfter": 259200, "minimumAge": 0}}"#).triage == TriageSettings(staleAfter: 259200, minimumAge: 0))
        // Too short to mean anything, or of the wrong type: the defaults, without losing the rest.
        #expect(try load(#"{"triage": {"staleAfter": 5, "minimumAge": -1}, "terminal": "warp"}"#) == Settings(terminal: "warp", triage: TriageSettings()))
        #expect(try load(#"{"triage": {"staleAfter": "soon"}}"#).triage == TriageSettings())
        #expect(try load("{}").triage == nil)
    }

    @Test func gatheringLooksUpTheBranchOfTheWorktreeAndSkipsWhatIsNotListed() async {
        let done = Session(summary: SessionSummary(id: "done0001", name: "old", cwd: "/Users/u/code/app", kind: "background", state: .done, startedAt: now - 3 * day))
        let busy = Session(summary: SessionSummary(id: "work0002", name: "busy", cwd: "/Users/u/code/app", kind: "background", state: .working, startedAt: now - 3 * day))
        let report = WorktreeReport(name: "fix", path: "/Users/u/code/app/.claude/worktrees/fix", uncommitted: 0, unpushed: 0)
        let asked = Asked()
        let gatherer = TriageGatherer(
            inspectWorktree: { $0.id == "done0001" ? report : nil },
            pullRequest: { branch, directory in
                await asked.add("\(branch) in \(directory)")
                return .merged(number: 7)
            },
            branchOf: { $0 == report.path ? "fix/login" : nil })
        let items = await gatherer.items(sessions: [done, busy], pins: Pins(), now: now)
        #expect(items.map(\.id) == ["done0001"])
        #expect(items.first?.verdict == .safeToRemove && items.first?.facts.branch == "fix/login")
        // Asked in the repository, not in the worktree, and only for the listed session.
        #expect(await asked.values == ["fix/login in /Users/u/code/app"])
    }

    actor Asked {
        var values: [String] = []
        func add(_ value: String) { values.append(value) }
    }
}

@Suite struct PullRequestLookupTests {
    static let fakeGH = Fixtures.directory.appendingPathComponent("fake-gh")

    func lookup(mode: String? = nil, log: URL? = nil) -> PullRequestLookup {
        var environment = ["PATH": "/usr/bin:/bin"]
        if let mode { environment["FAKE_GH_MODE"] = mode }
        if let log { environment["FAKE_GH_LOG"] = log.path }
        return PullRequestLookup(gh: Self.fakeGH, environment: environment)
    }

    func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("porchlight-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func readsEachStateOfAPullRequest() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        #expect(await lookup(mode: "merged").state(branch: "fix", in: repo.path) == .merged(number: 12))
        #expect(await lookup(mode: "open").state(branch: "fix", in: repo.path) == .open(number: 34))
        #expect(await lookup(mode: "closed").state(branch: "fix", in: repo.path) == .closed(number: 56))
        #expect(await lookup(mode: "none").state(branch: "fix", in: repo.path) == PullRequestState.none)
    }

    @Test func asksInTheRepositoryWithExactlyTheDocumentedArguments() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        let log = repo.appendingPathComponent("argv.log")
        _ = await lookup(log: log).state(branch: "feature/login form", in: repo.path)
        let recorded = try Data(contentsOf: log).split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        // The same folder, whichever of /var and /private/var the shell reports.
        #expect(recorded.first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath() } == repo.resolvingSymlinksInPath())
        #expect(Array(recorded.dropFirst()) == ["pr", "list", "--head", "feature/login form", "--state", "all", "--limit", "1", "--json", "number,state"])
    }

    @Test func whatCannotBeLookedUpIsUnknownNotAbsent() async throws {
        let repo = try scratch()
        defer { try? FileManager.default.removeItem(at: repo) }
        // gh failing, printing something else, or not being installed.
        #expect(await lookup(mode: "fail").state(branch: "fix", in: repo.path) == .unknown)
        #expect(await lookup(mode: "garbage").state(branch: "fix", in: repo.path) == .unknown)
        #expect(await PullRequestLookup(gh: nil).state(branch: "fix", in: repo.path) == .unknown)
        #expect(await PullRequestLookup(gh: URL(fileURLWithPath: "/nonexistent/gh")).state(branch: "fix", in: repo.path) == .unknown)
        // A folder that is gone, an empty branch, or a branch that could be read as a flag.
        let log = repo.appendingPathComponent("argv.log")
        #expect(await lookup(log: log).state(branch: "fix", in: repo.path + "/missing") == .unknown)
        #expect(await lookup(log: log).state(branch: "", in: repo.path) == .unknown)
        #expect(await lookup(log: log).state(branch: "--repo=someone/else", in: repo.path) == .unknown)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(PullRequestLookup.parse(#"[{"number": 1, "state": "DRAFTISH"}]"#) == .unknown)
        #expect(PullRequestLookup.parse("{}") == .unknown)
    }

    @Test func findsGhInTheUsualPlacesAndHonoursTheOverride() {
        #expect(PullRequestLookup.locateGH(environment: [:], isExecutable: { $0 == "/usr/local/bin/gh" })?.path == "/usr/local/bin/gh")
        #expect(PullRequestLookup.locateGH(environment: ["PORCHLIGHT_GH": "/custom/gh"], isExecutable: { _ in true })?.path == "/custom/gh")
        #expect(PullRequestLookup.locateGH(environment: [:], isExecutable: { _ in false }) == nil)
    }
}
