import Foundation
import Testing

@testable import PorchlightCore

@Suite struct PinStoreTests {
    let now = Date(timeIntervalSince1970: 1_791_540_000)

    @Test func pinningUnpinningAndQuietingAreRemembered() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-pins-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = Pins.fileURL(in: directory)
        #expect(Pins.load(from: url) == Pins())

        var pins = Pins()
        pins.pin("aaaa1111", now: now)
        pins.pin("bbbb2222", quiet: true, now: now)
        try pins.save(to: url)
        let loaded = Pins.load(from: url)
        #expect(loaded == pins)
        #expect(loaded.isPinned("aaaa1111") && loaded.isPinned("bbbb2222") && !loaded.isPinned("cccc3333"))
        #expect(loaded.quiet == ["bbbb2222"])

        // Making a pin quiet keeps the day it was pinned.
        pins.pin("aaaa1111", quiet: true, now: now + 86400)
        #expect(pins.sessions["aaaa1111"] == Pin(since: now, quiet: true))
        pins.unpin("aaaa1111")
        pins.unpin("never-pinned")
        #expect(pins.sessions.keys.sorted() == ["bbbb2222"])
    }

    @Test func aBrokenFileOrEntryLosesOnlyWhatCannotBeRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-pins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = Pins.fileURL(in: directory)
        try Data("not json".utf8).write(to: url)
        #expect(Pins.load(from: url) == Pins())
        try Data(#"{"sessions": {"good": {"since": "2026-10-09T10:00:00Z", "quiet": true}, "bad": "yes", "half": {"quiet": true}}}"#.utf8).write(to: url)
        #expect(Pins.load(from: url).sessions.keys.sorted() == ["good"])
        try Data(#"{"sessions": []}"#.utf8).write(to: url)
        #expect(Pins.load(from: url) == Pins())
    }
}

@Suite struct PinnedSessionsTests {
    let now = Date(timeIntervalSince1970: 1_791_540_000)

    func session(_ id: String, _ name: String, _ state: SessionState, waited: TimeInterval = 600, started: TimeInterval = 3600) -> Session {
        Session(
            summary: SessionSummary(id: id, name: name, cwd: "/Users/u/code/\(name)", kind: "background", state: state, startedAt: now - started),
            observedBlockedSince: state == .blocked ? now - waited : nil)
    }

    var sessions: [Session] {
        [
            session("wait0001", "review", .blocked),
            session("wait0002", "finance", .blocked, waited: 5 * 3600),
            session("work0003", "build", .working),
            session("done0004", "debug-notes", .done, started: 40 * 86400),
            session("done0005", "old", .done, started: 40 * 86400),
        ]
    }

    func sections(_ pins: Pins) -> [(title: String, rows: [InboxRow])] {
        InboxGroups(sessions: sessions, now: now).sections(now: now, pins: pins, pinned: sessions)
    }

    @Test func pinnedSessionsAreTheFirstSectionAndInNoOther() {
        var pins = Pins()
        pins.pin("wait0002", quiet: true, now: now)
        pins.pin("done0004", now: now)
        let result = sections(pins)
        #expect(result.first?.title == "Pinned")
        // By name; the finished one is there although it is too old for "Recently done".
        #expect(result.first?.rows.map(\.id) == ["done0004", "wait0002"])
        #expect(result.first?.rows.map(\.isPinned) == [true, true])
        #expect(result.first?.rows.map(\.isQuiet) == [false, true])
        let elsewhere = result.dropFirst().flatMap(\.rows).map(\.id)
        #expect(!elsewhere.contains("wait0002") && !elsewhere.contains("done0004"))
        #expect(elsewhere.contains("wait0001") && elsewhere.contains("work0003"))
    }

    @Test func withoutPinsThereIsNoPinnedSectionAndNothingElseChanges() {
        let plain = InboxGroups(sessions: sessions, now: now).sections(now: now)
        #expect(sections(Pins()).map(\.title) == plain.map(\.title))
        #expect(!plain.contains { $0.title == "Pinned" })
        #expect(plain.flatMap(\.rows).allSatisfy { !$0.isPinned && !$0.isQuiet })
        // A pin on a session that no longer exists shows nothing.
        var stale = Pins()
        stale.pin("gone9999", now: now)
        #expect(!sections(stale).contains { $0.title == "Pinned" })
    }

    @Test func aPinnedSessionCannotBeRemovedButCanStillBeStopped() {
        let working = session("work0003", "build", .working)
        #expect(InboxRow(session: working, now: now).canRemove)
        let pinned = InboxRow(session: working, pin: Pin(since: now), now: now)
        #expect(!pinned.canRemove && pinned.canStop && pinned.isPinned)
    }

    @Test func aQuietPinDoesNotLightTheLanternAndAPlainPinDoes() {
        var snapshot = StoreSnapshot()
        snapshot.sessions = sessions
        snapshot.fetchedAt = now
        // Two waiting, one of them for five hours.
        #expect(MenuBarStatus(snapshot: snapshot, now: now) == .overdue(count: 2))
        var pins = Pins()
        pins.pin("wait0002", now: now)
        #expect(MenuBarStatus(snapshot: snapshot, quiet: pins.quiet, now: now) == .overdue(count: 2))
        pins.pin("wait0002", quiet: true, now: now)
        #expect(MenuBarStatus(snapshot: snapshot, quiet: pins.quiet, now: now) == .waiting(count: 1))
        pins.pin("wait0001", quiet: true, now: now)
        #expect(MenuBarStatus(snapshot: snapshot, quiet: pins.quiet, now: now) == .idle)
    }

    actor Collected: ReminderDelivery {
        var delivered: [String] = []
        var withdrawn: [String] = []
        func deliver(_ reminder: Reminder) { delivered.append(reminder.id) }
        func withdraw(reminderIDs: [String]) { withdrawn += reminderIDs }
    }

    final class Muted: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: Set<String> = []
        var value: Set<String> {
            get { lock.withLock { ids } }
            set { lock.withLock { ids = newValue } }
        }
    }

    @Test func aQuietPinIsNotRemindedAndQuietingWithdrawsAReminderAlreadyShown() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-pin-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let delivery = Collected()
        let muted = Muted()
        let fixed = now
        let engine = ReminderEngine(
            delivery: delivery, stateURL: ReminderState.fileURL(in: directory),
            settings: { ReminderSettings(ladder: [900, 7200], repeatEvery: nil, digestMinute: nil) },
            muted: { muted.value }, now: { fixed })
        var snapshot = StoreSnapshot()
        snapshot.sessions = sessions
        snapshot.fetchedAt = now

        // Not muted: the one that has waited five hours is reminded.
        await engine.process(snapshot)
        #expect(await delivery.delivered == ["session-wait0002"])

        // Quieted: its reminder is taken back and nothing new is sent for it.
        muted.value = ["wait0002"]
        await engine.process(snapshot)
        #expect(await delivery.withdrawn == ["session-wait0002"])
        #expect(await delivery.delivered == ["session-wait0002"])
    }

    @Test func theStatusReportSaysWhichSessionsArePinned() throws {
        var pins = Pins()
        pins.pin("wait0002", quiet: true, now: now)
        pins.pin("work0003", now: now)
        let json = try StatusReport(sessions: sessions, pins: pins, generatedAt: now).json()
        let rows = try #require((try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["sessions"] as? [[String: Any]])
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0["id"] as? String ?? "", $0["pin"] as? String) })
        #expect(byID["wait0002"] == "quiet" && byID["work0003"] == "pinned")
        #expect(byID["wait0001"] == .some(nil) && byID["done0005"] == .some(nil))
    }
}
