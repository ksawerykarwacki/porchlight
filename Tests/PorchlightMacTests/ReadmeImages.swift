import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

/// Draws the pictures in the README from the app's own views, with made-up sessions.
///
///   PORCHLIGHT_README_DIR=docs/images swift test --filter ReadmeImages
///
/// Without the variable nothing is written; the test still draws everything, so a view that can
/// no longer be drawn with this data fails here.
@MainActor
@Suite struct ReadmeImages {
    static let now = Date(timeIntervalSince1970: 1_791_540_000)
    static let hour: TimeInterval = 3600

    /// A session as Claude Code would report it, with the details a waiting one carries.
    static func session(
        _ id: String, _ name: String, repo: String, state: SessionState, idle: TimeInterval, worktree: String? = nil, needs: String? = nil,
        question: (String, [String])? = nil, reply: String? = nil
    ) throws -> Session {
        var job: [String: Any] = ["state": state.rawValue, "name": name, "updatedAt": ISO8601DateFormatter().string(from: now - idle)]
        if let needs { job["needs"] = needs }
        if let reply { job["suggestedReply"] = reply }
        if let question {
            job["block"] = ["questions": [["question": question.0, "options": question.1.map { ["label": $0, "description": ""] }]]]
        }
        let folder = "/Users/you/code/\(repo)" + (worktree.map { "/.claude/worktrees/\($0)" } ?? "")
        if let worktree {
            job["worktreePath"] = folder
            job["worktreeBranch"] = worktree
        }
        return Session(
            summary: SessionSummary(
                id: id, sessionId: "\(id)-0000-4000-8000-000000000000", name: name, cwd: folder, kind: "background", state: state, startedAt: now - idle - 1800),
            job: try JSONDecoder().decode(JobState.self, from: JSONSerialization.data(withJSONObject: job)),
            observedBlockedSince: state == .blocked ? now - idle : nil)
    }

    static func sessions() throws -> [Session] {
        [
            try session(
                "a1b2c3d4", "migrate invoices to the new schema", repo: "billing", state: .blocked, idle: 26 * hour, worktree: "invoice-schema",
                needs: "answer: Drop the legacy_total column now, or keep it for one more release?",
                question: ("Drop the legacy_total column now, or keep it for one more release?", ["Keep it one release (Recommended)", "Drop it now"]),
                reply: "Keep it for one release, then drop it."),
            try session(
                "b2c3d4e5", "fix flaky checkout test", repo: "storefront", state: .blocked, idle: 0.4 * hour,
                needs: "approve Bash: npm test -- checkout --runInBand"),
            try session("c3d4e5f6", "upgrade the iOS app to Swift 6", repo: "mobile", state: .working, idle: 120),
            try session("d4e5f6a7", "write the API reference", repo: "docs", state: .working, idle: 40),
            try session("e5f6a7b8", "bump dependencies", repo: "storefront", state: .done, idle: 0.2 * hour),
        ]
    }

    func write(_ view: some View, named name: String, dark: Bool) throws {
        let framed = view
            .padding(dark ? 0 : 0)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 300 && image.size.height > 150)
        guard let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_README_DIR"], !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name)\(dark ? "-dark" : "").png"))
    }

    /// The menu-bar panel as a card: its window's surface is the system's, so one is drawn here.
    func panel(_ view: some View, dark: Bool) -> some View {
        view
            .background(dark ? Color(red: 0.13, green: 0.13, blue: 0.15) : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.gray.opacity(dark ? 0.45 : 0.3), lineWidth: 1))
            .padding(16)
    }

    @Test func thePanel() throws {
        var snapshot = StoreSnapshot()
        snapshot.sessions = try Self.sessions()
        snapshot.fetchedAt = Self.now
        for dark in [false, true] {
            try write(panel(InboxView(snapshot: snapshot, now: Self.now, scrolls: false), dark: dark), named: "panel", dark: dark)
        }
    }

    @Test func triageWithASummary() async throws {
        let day = 24 * Self.hour
        let idle = [
            try Self.session("f6a7b8c9", "rework the search index", repo: "search", state: .done, idle: 3 * day, worktree: "search-index"),
            try Self.session("a7b8c9d0", "explain the billing cron", repo: "billing", state: .done, idle: 9 * day),
            try Self.session("b8c9d0e1", "prototype the new onboarding", repo: "mobile", state: .done, idle: 4 * day, worktree: "onboarding"),
            try Self.session(
                "c9d0e1f2", "debug the login redirect loop", repo: "storefront", state: .blocked, idle: 14 * day, worktree: "login-redirect",
                needs: "answer: Safari or Chrome first?"),
        ]
        let gatherer = TriageGatherer(
            inspectWorktree: { session in
                switch session.id {
                case "f6a7b8c9": WorktreeReport(name: "search-index", path: session.summary.cwd, uncommitted: 0, unpushed: 0)
                case "b8c9d0e1": WorktreeReport(name: "onboarding", path: session.summary.cwd, uncommitted: 3, unpushed: 1)
                case "c9d0e1f2": WorktreeReport(name: "login-redirect", path: session.summary.cwd, uncommitted: 0, unpushed: 0)
                default: nil
                }
            },
            pullRequest: { branch, _ in branch == "search-index" ? .merged(number: 212) : .none },
            branchOf: { _ in nil })
        var state = TriageState()
        state.items = await gatherer.items(sessions: idle, pins: Pins(), now: Self.now)
        state.hasLoaded = true
        state.plan = WrapUpPlan(chosen: .onDevice, model: "haiku", onDevice: .available)
        var note = SessionNote(
            id: "c9d0e1f2", sessionID: "c9d0e1f2-0000-4000-8000-000000000000", name: "debug the login redirect loop", repo: "storefront",
            directory: "/Users/you/code/storefront", branch: "login-redirect",
            summary: "Doing: tracking down why sign-in redirects in a loop.\nStopped at: a fix for the cookie's SameSite setting is written; asked whether to test Safari or Chrome first.\nWorth keeping: the finding that the loop only happens behind the staging proxy.",
            model: WrapUp.onDeviceModelName, createdAt: Self.now - 600)
        note.engine = .onDevice
        note.turnsRead = 14
        note.isPartial = true
        state.notes = [note.id: note]
        #expect(state.items.count == 4)
        for dark in [false, true] {
            var actions = InboxActions()
            actions.showsTriage = true
            actions.triageNow = Self.now
            actions.triage = state
            try write(panel(InboxView(snapshot: StoreSnapshot(), now: Self.now, actions: actions, scrolls: false), dark: dark), named: "triage", dark: dark)
        }
    }

    func palette() throws -> PaletteHarness {
        let harness = try PaletteHarness(names: ["storefront", "billing", "mobile", "docs", "search", "infra"])
        harness.probe.rows = try Self.sessions().map { InboxRow(session: $0, now: Self.now) }
        return harness
    }

    @Test func thePalette() async throws {
        let harness = try palette()
        await harness.model.begin()
        for dark in [false, true] {
            try write(PaletteView(model: harness.model, hover: HoverTracker(), drawsFields: false).padding(16), named: "palette", dark: dark)
        }
        harness.model.setQuery("store")
        harness.model.moveSelection(by: 5)
        if harness.model.selectedRepo == nil, let repo = harness.model.results.first { harness.model.select(.repo(repo)) }
        harness.model.confirmFolder()
        harness.model.setPrompt("Add a retry with backoff to the payment webhook, and a test that fails without it")
        #expect(harness.model.step == .prompt)
        for dark in [false, true] {
            try write(PaletteView(model: harness.model, hover: HoverTracker(), drawsFields: false).padding(16), named: "palette-prompt", dark: dark)
        }
    }

    @Test func theNotes() async throws {
        let harness = try palette()
        func note(_ id: String, _ name: String, _ repo: String, _ summary: String, days: Double, branch: String? = nil, onDevice: Bool = true) -> SessionNote {
            var note = SessionNote(
                id: id, sessionID: "\(id)-0000-4000-8000-000000000000", name: name, repo: repo, directory: "/Users/u/code/\(repo)", branch: branch,
                pullRequest: branch == nil ? nil : "PR #212 is merged", summary: summary, model: onDevice ? WrapUp.onDeviceModelName : "haiku",
                createdAt: Self.now - days * 24 * Self.hour)
            if onDevice {
                note.engine = .onDevice
                note.turnsRead = 12
                note.isPartial = true
            }
            return note
        }
        harness.probe.notes = [
            note("a1b2c3d4", "migrate invoices to the new schema", "billing", "Doing: moving invoices to the new schema.\nStopped at: asking whether to drop legacy_total.\nWorth keeping: nothing.", days: 1),
            note(
                "f6a7b8c9", "rework the search index", "search",
                "Doing: replacing the nightly rebuild with incremental updates.\nStopped at: merged; the old cron job is still scheduled and should be removed.\nWorth keeping: the benchmark showing rebuilds drop from 40 minutes to 90 seconds.",
                days: 6, branch: "search-index"),
            note("0a1b2c3d", "explain the billing cron", "billing", "Doing: explaining what the cron does.\nStopped at: done.\nWorth keeping: nothing.", days: 21, onDevice: false),
        ]
        harness.probe.conversations = ["f6a7b8c9-0000-4000-8000-000000000000"]
        await harness.model.begin()
        harness.model.toggleNotes()
        harness.model.moveNoteSelection(by: 1)
        #expect(harness.model.selectedNote?.id == "f6a7b8c9")
        for dark in [false, true] {
            try write(PaletteView(model: harness.model, hover: HoverTracker(), drawsFields: false).padding(16), named: "notes", dark: dark)
        }
    }
}
