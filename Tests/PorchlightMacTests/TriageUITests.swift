import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

/// Sessions, pins and removals for a triage model under test.
@MainActor
final class TriageWorld {
    nonisolated static let now = Date(timeIntervalSince1970: 1_791_540_000)
    nonisolated static let day: TimeInterval = 86400

    var sessions: [Session]
    var pins = Pins()
    var removed: [String] = []
    var reloads = 0
    var gathers = 0
    /// Session ids Claude Code refuses to remove, with what it says.
    var refusals: [String: String] = [:]
    /// Each summary asked for, as "id model".
    var wrapped: [String] = []
    /// What the summariser answers instead of a summary.
    var wrapUpFailure: WrapUpFailure?
    let archive = NotesArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-triage-notes-\(UUID().uuidString)/notes"))
    /// When set, a summary waits here until `release` is called, the way a real one takes a while.
    var holdsWrapUp = false
    /// The engine chosen and whether this Mac has the on-device model. Claude unless a test says otherwise.
    nonisolated(unsafe) var plan = WrapUpPlan(chosen: .claude, model: "haiku", onDevice: .missing)
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func release() {
        holdsWrapUp = false
        waiting.forEach { $0.resume() }
        waiting = []
    }

    init() {
        func session(_ id: String, _ name: String, _ state: String, idle: TimeInterval, waited: TimeInterval? = nil) -> Session {
            Session(
                summary: SessionSummary(id: id, name: name, cwd: "/Users/u/code/app", kind: "background", state: SessionState(rawValue: state), startedAt: Self.now - idle),
                observedBlockedSince: waited.map { Self.now - $0 })
        }
        sessions = [
            session("safe0001", "merged fix", "done", idle: 3 * Self.day),
            session("safe0002", "old question", "done", idle: 9 * Self.day),
            session("work0003", "unsaved work", "done", idle: 4 * Self.day),
            session("open0004", "open pull request", "done", idle: 2 * Self.day),
            session("wait0005", "forgotten", "blocked", idle: 20 * Self.day, waited: 14 * Self.day),
            session("busy0006", "still running", "working", idle: 5 * Self.day),
            session("new00007", "just finished", "done", idle: 600),
        ]
    }

    var model: TriageModel {
        let gatherer = TriageGatherer(
            inspectWorktree: { session in
                switch session.id {
                case "safe0001": WorktreeReport(name: "fix", path: "/w/fix", uncommitted: 0, unpushed: 0)
                case "work0003": WorktreeReport(name: "wip", path: "/w/wip", uncommitted: 2, unpushed: 1)
                case "open0004": WorktreeReport(name: "feat", path: "/w/feat", uncommitted: 0, unpushed: 0)
                default: nil
                }
            },
            pullRequest: { branch, _ in branch == "fix" ? .merged(number: 12) : branch == "feat" ? .open(number: 34) : .none },
            branchOf: { $0.split(separator: "/").last.map(String.init) })
        return TriageModel(services: TriageModel.Services(
            sessions: { [self] in
                self.gathers += 1
                return self.sessions
            },
            pins: { [self] in self.pins },
            gatherer: gatherer,
            remove: { [self] id in
                if let words = self.refusals[id] { return .refused(words) }
                self.removed.append(id)
                self.sessions.removeAll { $0.id == id }
                return .done("removed \(id)")
            },
            reload: { [self] in self.reloads += 1 },
            now: { TriageWorld.now },
            wrapUp: { [self] item, engine, model in
                self.wrapped.append("\(item.id) \(engine == .onDevice ? "on-device" : model)")
                if self.holdsWrapUp {
                    await withCheckedContinuation { self.waiting.append($0) }
                }
                if let failure = self.wrapUpFailure { return .failure(failure) }
                let note = SessionNote(
                    id: item.id, sessionID: "22222222-0000-4000-8000-000000000000", name: item.session.name, repo: item.session.location.repoName,
                    directory: item.session.summary.cwd, branch: item.facts.branch, summary: "Doing: \(item.session.name).\nStopped at: waiting.\nWorth keeping: nothing.",
                    model: engine == .onDevice ? WrapUp.onDeviceModelName : model, createdAt: TriageWorld.now)
                try? self.archive.save(note)
                return .success(note)
            },
            notes: { [archive] in archive.all() },
            wrapUpPlan: { [self] in self.plan }))
    }
}

@MainActor
@Suite struct TriageModelTests {
    @Test func loadingGroupsIdleSessionsByVerdictAndLeavesOutTheRest() async {
        let world = TriageWorld()
        let model = world.model
        #expect(!model.hasLoaded && model.items.isEmpty)
        await model.load()
        #expect(model.hasLoaded && !model.isLoading)
        #expect(model.items(.safeToRemove).map(\.id) == ["safe0001", "safe0002"])
        #expect(model.items(.needsDecision).map(\.id) == ["work0003"])
        #expect(model.items(.stale).map(\.id) == ["wait0005"])
        #expect(model.items(.keep).map(\.id) == ["open0004"])
        // Working and just-finished sessions are not there at all.
        #expect(!model.items.contains { $0.id == "busy0006" || $0.id == "new00007" })
        #expect(model.items.first { $0.id == "safe0001" }?.reason == "worktree clean, PR #12 is merged")
        #expect(model.items.first { $0.id == "work0003" }?.reason == "2 uncommitted files, 1 commit on no remote")
    }

    @Test func aPinnedSessionIsNeverListed() async {
        let world = TriageWorld()
        world.pins.pin("safe0002", now: TriageWorld.now)
        let model = world.model
        await model.load()
        #expect(model.safe.map(\.id) == ["safe0001"])
    }

    @Test func nothingIsRemovedUntilTheBulkQuestionIsAnswered() async {
        let world = TriageWorld()
        let model = world.model
        // Before a look there is nothing to ask about.
        model.askRemoveSafe()
        #expect(!model.isConfirmingBulk)
        await model.load()
        // Confirming with no question up does nothing.
        await model.confirmRemoveSafe()
        #expect(world.removed.isEmpty)

        model.askRemoveSafe()
        #expect(model.isConfirmingBulk && world.removed.isEmpty)
        model.cancelRemoveSafe()
        await model.confirmRemoveSafe()
        #expect(world.removed.isEmpty && !model.isConfirmingBulk)
    }

    @Test func confirmingRemovesOnlyTheSafeOnesThenLooksAgain() async {
        let world = TriageWorld()
        let model = world.model
        await model.load()
        let looksBefore = world.gathers
        model.askRemoveSafe()
        await model.confirmRemoveSafe()
        #expect(world.removed == ["safe0001", "safe0002"])
        #expect(model.summary == "2 sessions removed.")
        #expect(model.refusals.isEmpty && model.removing == nil)
        // The sessions were read again once, and the list was rebuilt without the removed ones.
        #expect(world.reloads == 1 && world.gathers == looksBefore + 1)
        #expect(model.safe.isEmpty)
        #expect(model.items.map(\.id) == ["work0003", "wait0005", "open0004"])
        // With nothing safe left there is nothing to ask.
        model.askRemoveSafe()
        #expect(!model.isConfirmingBulk)
        model.dismissResult()
        #expect(model.summary == nil)
    }

    @Test func whatClaudeCodeRefusesIsReportedInItsWordsAndNeverForced() async {
        let world = TriageWorld()
        world.refusals["safe0002"] = "kept safe0002 — its worktree is still at “/w/x”\n  discard: claude rm safe0002 --discard-unpushed 1a2b3c4@wt-9"
        let model = world.model
        await model.load()
        model.askRemoveSafe()
        await model.confirmRemoveSafe()
        // The other one went; the refused one was tried once, plainly, and is still there.
        #expect(world.removed == ["safe0001"])
        #expect(model.summary == "1 session removed; Claude Code refused 1, listed below.")
        #expect(model.refusals.map(\.name) == ["old question"])
        #expect(model.refusals.first?.text.contains("--discard-unpushed 1a2b3c4@wt-9") == true)
        #expect(world.sessions.contains { $0.id == "safe0002" })
    }

    @Test func aSessionPinnedAfterTheLookIsNotRemoved() async {
        let world = TriageWorld()
        let model = world.model
        await model.load()
        model.askRemoveSafe()
        world.pins.pin("safe0001", now: TriageWorld.now)
        await model.confirmRemoveSafe()
        #expect(world.removed == ["safe0002"])
        #expect(model.summary == "1 session removed.")
    }

    @Test func keepingASessionTakesItsRowAwayAtOnceAndSaysWhereItWent() async throws {
        let world = TriageWorld()
        let model = world.model
        await model.load()
        model.askRemoveSafe()
        model.exclude("safe0001")
        // Gone from the list without another look, and the bulk question still stands for the rest.
        #expect(!model.items.contains { $0.id == "safe0001" })
        #expect(model.safe.map(\.id) == ["safe0002"] && model.isConfirmingBulk)
        model.exclude("safe0002")
        // Nothing safe is left, so there is nothing left to confirm.
        #expect(model.safe.isEmpty && !model.isConfirmingBulk)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-triage-keep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inbox = InboxModel(settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory))
        var snapshot = StoreSnapshot()
        snapshot.sessions = world.sessions
        inbox.apply(snapshot)
        inbox.keep(sessionID: "wait0005")
        #expect(inbox.pins.isPinned("wait0005"))
        #expect(inbox.notice == "Pinned forgotten. It is under Pinned on the Sessions tab and will not be suggested for removal.")
        #expect(inbox.rows.first?.id == "wait0005")
        // Keeping it again, or keeping something that is not there, changes nothing.
        inbox.keep(sessionID: "wait0005")
        inbox.keep(sessionID: "gone9999")
        #expect(inbox.pins.sessions.count == 1)
    }

    /// The path the app wires in: plain removal through the inbox model, which refuses a pinned
    /// or vanished session before running anything and never passes an override.
    @Test func theInboxRemovesPlainlyAndOnlyWhatItStillCan() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-triage-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let inbox = InboxModel(settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory))
        var snapshot = StoreSnapshot()
        snapshot.sessions = TriageWorld().sessions
        inbox.apply(snapshot)
        let probe = ControlProbe()
        inbox.runControl = { action, id, overrides in probe.run(action, id, overrides) }

        #expect(await inbox.removePlainly(sessionID: "safe0001") == .done(""))
        #expect(probe.calls.count == 1 && probe.calls[0].0 == .remove && probe.overrides == [[]])
        inbox.togglePin(sessionID: "safe0002")
        #expect(await inbox.removePlainly(sessionID: "safe0002").succeeded == false)
        #expect(await inbox.removePlainly(sessionID: "gone9999").succeeded == false)
        #expect(probe.calls.count == 1)
    }
}

@MainActor
@Suite struct TriageViewTests {
    func state(loaded: Bool = true) async -> TriageState {
        let model = TriageWorld().model
        if loaded { await model.load() }
        return TriageState(model)
    }

    func height(_ actions: InboxActions, named name: String? = nil) throws -> CGFloat {
        let view = InboxView(snapshot: StoreSnapshot(), now: TriageWorld.now, actions: actions, scrolls: false)
        let renderer = ImageRenderer(content: view.background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        if let name, let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return image.size.height
    }

    @Test func theHeadlineSaysWhatWasFound() async {
        #expect(TriagePage.headline(await state(loaded: false)) == "Looking at what each idle session holds…")
        #expect(TriagePage.headline(await state()) == "5 idle sessions; 2 can be removed without losing anything.")
        var none = TriageState()
        none.hasLoaded = true
        #expect(TriagePage.headline(none).hasPrefix("Nothing to triage."))
        var noSafe = await state()
        noSafe.items.removeAll { $0.verdict == .safeToRemove }
        #expect(TriagePage.headline(noSafe) == "3 idle sessions; none can be removed without a decision.")
        var removing = await state()
        removing.removing = "safe0001"
        #expect(TriagePage.headline(removing) == "Removing merged fix…")
    }

    @Test func theTabDrawsItsSectionsAndGrowsWithItsQuestion() async throws {
        var actions = InboxActions()
        actions.showsTriage = true
        actions.triageNow = TriageWorld.now
        let empty = try height(actions)
        actions.triage = await state()
        let full = try height(actions, named: "triage")
        // Five rows under four headings.
        #expect(full > empty + 5 * 50)

        actions.triage.isConfirmingBulk = true
        let asking = try height(actions, named: "triage-asking")
        #expect(asking > full + 30)

        actions.triage.isConfirmingBulk = false
        actions.triage.summary = "1 session removed; Claude Code refused 1, listed below."
        actions.triage.refusals = [.init(id: "safe0002", name: "old question", text: "kept safe0002 — its worktree is still at “/w/x”")]
        #expect(try height(actions, named: "triage-result") > full + 40)

        // A removal question about one row is drawn in that row.
        actions.triage.summary = nil
        actions.triage.refusals = []
        actions.pendingControl = PendingControl(sessionID: "work0003", name: "unsaved work", action: .remove)
        #expect(try height(actions) > full + 40)
    }

    @Test func theThreeTabsAreOneHeightInTheLivePanel() async throws {
        func live(_ configure: (inout InboxActions) -> Void) -> CGFloat {
            var actions = InboxActions()
            configure(&actions)
            return NSHostingController(rootView: InboxView(snapshot: StoreSnapshot(), now: TriageWorld.now, actions: actions)).sizeThatFits(in: .zero).height
        }
        let triage = await state()
        let sessions = live { $0.triage = triage }
        let onTriage = live { $0.triage = triage; $0.showsTriage = true }
        let onSettings = live { $0.triage = triage; $0.showsSettings = true }
        #expect(sessions == onTriage && onTriage == onSettings)
        #expect(sessions > 300)
    }

    /// When another tab makes the panel taller than the settings would be alone, the settings
    /// scroll in all of that height instead of leaving a blank band under them.
    @Test func theSettingsFillThePanelWhenAnotherTabMakesItTaller() async throws {
        func scrollHeights(_ configure: (inout InboxActions) -> Void) -> [CGFloat] {
            var actions = InboxActions()
            configure(&actions)
            let host = NSHostingView(rootView: InboxView(snapshot: StoreSnapshot(), now: TriageWorld.now, actions: actions))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            var found: [CGFloat] = []
            func walk(_ view: NSView) {
                if view is NSScrollView { found.append(view.frame.height) }
                view.subviews.forEach(walk)
            }
            walk(host)
            return found.sorted()
        }
        // Many idle sessions: the Triage tab is at its limit, which is taller than the settings' own.
        var tall = await state()
        tall.items = (0..<4).flatMap { _ in tall.items }
        let heights = scrollHeights { $0.triage = tall; $0.showsSettings = true }
        let tallest = try #require(heights.last)
        #expect(tallest > 400)
        // The settings' scroll view is as tall as the tallest tab's.
        #expect(heights.filter { abs($0 - tallest) < 1 }.count >= 2, "scroll views are \(heights)")

        // With little in the other tabs the settings still get their own height, not less.
        let alone = scrollHeights { $0.showsSettings = true }
        #expect((alone.last ?? 0) >= 359, "scroll views are \(alone)")
    }

    @Test func theFootersRefreshDoesWhatTheShownTabNeeds() async {
        var calls: [String] = []
        var actions = InboxActions()
        actions.refresh = { calls.append("sessions") }
        actions.reloadTriage = { calls.append("triage") }
        actions.refreshSettings = { calls.append("settings") }

        // Sessions: the sessions, and nothing that asks git or GitHub.
        FooterRefresh(actions).action()
        #expect(calls == ["sessions"] && FooterRefresh(actions).title == "Refresh")

        // Triage: one action that reads the sessions and then looks, and says so while it runs.
        actions.showsTriage = true
        FooterRefresh(actions).action()
        #expect(calls == ["sessions", "triage"])
        actions.triage.isLoading = true
        #expect(FooterRefresh(actions).title == "Looking…")
        actions.triage.isLoading = false
        #expect(FooterRefresh(actions).title == "Refresh" && FooterRefresh(actions).help.contains("idle"))

        // Settings: the sessions, and whether this Mac has the on-device model.
        actions.showsTriage = false
        actions.showsSettings = true
        FooterRefresh(actions).action()
        #expect(calls == ["sessions", "triage", "sessions", "settings"])
        // A look in progress on another tab does not rename the button here.
        actions.triage.isLoading = true
        #expect(FooterRefresh(actions).title == "Refresh")

        // The Triage tab has no button of its own for it any more: with nothing safe and no
        // notes, its header is the one line of text.
        var empty = InboxActions()
        empty.showsTriage = true
        empty.triage.hasLoaded = true
        var withSafe = empty
        withSafe.triage = await state()
        #expect(try! height(withSafe) > (try! height(empty)))
    }

    @Test func theTabsCallTheirActions() {
        var calls: [String] = []
        var actions = InboxActions()
        actions.setShowsTriage = { calls.append("triage \($0)") }
        actions.askRemoveSafe = { calls.append("ask") }
        actions.confirmRemoveSafe = { calls.append("confirm") }
        actions.cancelRemoveSafe = { calls.append("cancel") }
        actions.reloadTriage = { calls.append("reload") }
        actions.setShowsTriage(true)
        actions.askRemoveSafe()
        actions.cancelRemoveSafe()
        actions.confirmRemoveSafe()
        actions.reloadTriage()
        #expect(calls == ["triage true", "ask", "cancel", "confirm", "reload"])
    }
}
