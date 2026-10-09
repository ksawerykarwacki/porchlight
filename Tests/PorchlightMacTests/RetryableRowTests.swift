import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightMac
@testable import PorchlightUI

/// Remembers what it was asked to open and opens nothing.
actor RecordingLauncher: TerminalLauncher {
    private(set) var opened: [TerminalCommand] = []
    func open(_ command: TerminalCommand) -> LaunchOutcome {
        opened.append(command)
        return .opened(terminal: "Test Terminal")
    }
}

@MainActor
@Suite struct RetryableRowTests {
    let now = Date(timeIntervalSince1970: 1_791_480_200)
    let limit = "You've hit your session limit · resets 3:45pm"

    /// A waiting session with the given text as what it waits on.
    func waiting(_ id: String, needs: String) throws -> Session {
        let job = try JSONDecoder().decode(JobState.self, from: JSONSerialization.data(withJSONObject: [
            "state": "working", "name": "session \(id)", "tempo": "blocked", "needs": needs,
        ]))
        return Session(
            summary: SessionSummary(id: id, name: "session \(id)", cwd: "/Users/u/code/alpha", state: .blocked),
            job: job, observedBlockedSince: now - 600)
    }

    func height(_ row: InboxRow, _ actions: InboxActions = InboxActions()) throws -> Int {
        try render(InboxRowView(row: row, actions: actions, hover: HoverTracker(), drawsMenus: false)).pixelsHigh
    }

    @Test func aRowThatCanBeRetriedSaysSoAndShowsRetryAndOthersShowNeither() throws {
        // Two texts of the same length on one line, so only the retry area can differ.
        let failed = InboxRow(session: try waiting("f0f0f0f0", needs: limit), now: now)
        let asking = InboxRow(session: try waiting("a0a0a0a0", needs: "Should I raise the rate limit to 100 or not?"), now: now)
        #expect(failed.isRetryable && !asking.isRetryable)
        #expect(failed.kind == .waiting && asking.kind == .waiting)

        let plain = try height(asking)
        let retryable = try height(failed)
        // The label and the button take a line of their own under the row (drawn at twice the size).
        #expect(retryable >= plain + 40)

        // The same failed session without the mark is exactly as tall as the ordinary row: the
        // extra line is the retry area and nothing else.
        let unmarked = InboxRow(session: try waiting("f0f0f0f0", needs: limit), transientErrors: TransientErrors(patterns: []), now: now)
        #expect(!unmarked.isRetryable)
        #expect(try height(unmarked) == plain)

        try render(InboxRowView(row: failed, actions: InboxActions(), hover: HoverTracker(), drawsMenus: false), named: "row-retryable")
        try render(InboxRowView(row: asking, actions: InboxActions(), hover: HoverTracker(), drawsMenus: false), named: "row-not-retryable")
    }

    @Test func theRetryAreaIsDrawnBelowTheRowsOwnContent() throws {
        let marked = InboxRow(session: try waiting("f0f0f0f0", needs: limit), now: now)
        let unmarked = InboxRow(session: try waiting("f0f0f0f0", needs: limit), transientErrors: TransientErrors(patterns: []), now: now)
        let with = try render(InboxRowView(row: marked, actions: InboxActions(), hover: HoverTracker(), drawsMenus: false))
        let without = try render(InboxRowView(row: unmarked, actions: InboxActions(), hover: HoverTracker(), drawsMenus: false))
        // Everything the unmarked row draws is drawn the same in the marked one, above the new line.
        let shared = without.pixelsHigh - 20
        #expect(try inkRows(with, upTo: shared) == inkRows(without, upTo: shared))
        // And the new line has ink in it: a label and a button, not blank space.
        let added = try inkRows(with, from: without.pixelsHigh - 16)
        #expect(added.count >= 12)
    }

    @Test func theInboxMarksRowsByThePatternsItIsGiven() throws {
        var snapshot = StoreSnapshot()
        snapshot.fetchedAt = now
        snapshot.sessions = [try waiting("f0f0f0f0", needs: "The flux capacitor drained before it finished")]

        var actions = InboxActions()
        let byDefault = try render(InboxView(snapshot: snapshot, now: now, actions: actions, scrolls: false)).pixelsHigh
        actions.transientErrors = TransientErrors(patterns: ["flux capacitor drained"])
        let byMine = try render(InboxView(snapshot: snapshot, now: now, actions: actions, scrolls: false), named: "inbox-retryable").pixelsHigh
        #expect(byMine >= byDefault + 40)
    }

    @Test func theRetryButtonsActionReachesTheModelsRetry() throws {
        var retried: [String] = []
        var actions = InboxActions()
        // Does nothing until something is wired to it.
        actions.retry("f0f0f0f0")
        actions.retry = { retried.append($0) }
        actions.retry("f0f0f0f0")
        #expect(retried == ["f0f0f0f0"])
        #expect(actions.transientErrors == TransientErrors())
    }

    func model(_ launcher: RecordingLauncher, settings: PorchlightCore.Settings = PorchlightCore.Settings(), copies: Box<[String]>) throws -> InboxModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-retry-\(UUID().uuidString)")
        let url = PorchlightCore.Settings.fileURL(in: directory)
        try settings.save(to: url)
        let model = InboxModel(
            launcher: launcher, locator: ClaudeLocator(override: "/custom/claude", isExecutable: { $0 == "/custom/claude" }),
            settingsURL: url, remindersURL: ReminderState.fileURL(in: directory), clock: { [now] in now })
        // Never the real clipboard.
        model.copy = { text in
            copies.value.append(text)
            return true
        }
        return model
    }

    /// Waits for the model's background work, up to two seconds.
    func settle(until done: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await done() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func retryOpensTheSessionAndPutsContinueOnTheClipboard() async throws {
        let launcher = RecordingLauncher()
        let copies = Box<[String]>([])
        let model = try model(launcher, copies: copies)
        var snapshot = StoreSnapshot()
        snapshot.sessions = [try waiting("f0f0f0f0", needs: limit), try waiting("a0a0a0a0", needs: "Which timeout should I raise?")]
        model.apply(snapshot)

        model.retry(sessionID: "f0f0f0f0")
        try await settle { !copies.value.isEmpty }

        let opened = await launcher.opened
        #expect(opened.map(\.arguments) == [["/custom/claude", "attach", "f0f0f0f0"]])
        #expect(opened.first?.cwd == "/Users/u/code/alpha")
        #expect(copies.value == ["continue"])
        try await settle { model.notice != nil }
        #expect(model.notice?.contains("continue") == true)
    }

    @Test func retryDoesNothingForASessionThatIsNotWaitingOnAFailure() async throws {
        let launcher = RecordingLauncher()
        let copies = Box<[String]>([])
        let model = try model(launcher, copies: copies)
        var snapshot = StoreSnapshot()
        snapshot.sessions = [
            try waiting("a0a0a0a0", needs: "Should I raise the rate limit to 100?"),
            try waiting("b0b0b0b0", needs: "approve Bash: echo \"\(limit)\""),
        ]
        model.apply(snapshot)

        for id in ["a0a0a0a0", "b0b0b0b0", "no-such-session"] {
            model.retry(sessionID: id)
            #expect(model.notice == "That session is not waiting on something that can be retried", "\(id)")
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(await launcher.opened.isEmpty)
        #expect(copies.value.isEmpty)
    }

    @Test func theModelReadsItsPatternsAndItsLineFromSettingsJSON() async throws {
        let launcher = RecordingLauncher()
        let copies = Box<[String]>([])
        let custom = TransientErrors(patterns: ["flux capacitor drained"], resend: "try that again")
        let model = try model(launcher, settings: PorchlightCore.Settings(transientErrors: custom), copies: copies)
        #expect(model.transientErrors == custom)
        var snapshot = StoreSnapshot()
        snapshot.sessions = [try waiting("f0f0f0f0", needs: limit), try waiting("c0c0c0c0", needs: "The flux capacitor drained")]
        model.apply(snapshot)

        // With the user's patterns the usual failure is no longer one, and theirs is.
        model.retry(sessionID: "f0f0f0f0")
        model.retry(sessionID: "c0c0c0c0")
        try await settle { !copies.value.isEmpty }
        #expect(await launcher.opened.map(\.sessionID) == ["c0c0c0c0"])
        #expect(copies.value == ["try that again"])

        // Without the entry the defaults apply.
        #expect(try self.model(launcher, copies: copies).transientErrors == TransientErrors())
    }

    /// The pixel rows that hold something darker than the background, as offsets from the top.
    /// Thresholded, so the one-level drift between a process's first renders and later ones
    /// cannot change the answer.
    func inkRows(_ bitmap: NSBitmapImageRep, from: Int = 0, upTo: Int? = nil) throws -> [Int] {
        let data = try #require(bitmap.bitmapData)
        let samples = bitmap.samplesPerPixel
        return (from..<(upTo ?? bitmap.pixelsHigh)).filter { row in
            let start = row * bitmap.bytesPerRow
            return (0..<bitmap.pixelsWide).contains { x in
                let p = start + x * samples
                return Int(data[p]) + Int(data[p + 1]) + Int(data[p + 2]) < 3 * 190
            }
        }
    }

    @discardableResult
    func render(_ view: some View, named name: String? = nil) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: 400).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        if let name, let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }
}
