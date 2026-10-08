import Foundation
import Testing

@testable import PorchlightCore

func nextChange(of stream: AsyncStream<Void>, within timeout: Duration) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() != nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

/// A trigger the test fires by hand.
final class ManualTrigger: ChangeTrigger, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<Void>.Continuation] = []

    func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        lock.lock()
        continuations.append(continuation)
        lock.unlock()
        return stream
    }

    var isObserved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !continuations.isEmpty
    }

    func fire() {
        lock.lock()
        defer { lock.unlock() }
        for continuation in continuations { continuation.yield() }
    }
}

@Suite struct ChangeWatchTests {
    func jobsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-watch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("11111111"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("11111111/state.json"))
        return directory
    }

    @Test func firesWhenAStateFileIsRewritten() async throws {
        let directory = try jobsDirectory()
        let stream = PollingChangeWatcher(directory: directory, interval: .milliseconds(50)).changes()
        try await Task.sleep(for: .milliseconds(150))
        try Data(#"{"state":"blocked","name":"longer than before"}"#.utf8).write(to: directory.appendingPathComponent("11111111/state.json"))
        #expect(await nextChange(of: stream, within: .seconds(5)))
    }

    @Test func firesWhenAJobDirectoryAppearsEvenWithoutAStateFile() async throws {
        let directory = try jobsDirectory()
        let stream = PollingChangeWatcher(directory: directory, interval: .milliseconds(50)).changes()
        try await Task.sleep(for: .milliseconds(150))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("22222222"), withIntermediateDirectories: true)
        #expect(await nextChange(of: stream, within: .seconds(5)))
    }

    @Test func staysQuietWhenNothingChangesOrTheDirectoryIsMissing() async throws {
        let directory = try jobsDirectory()
        let quiet = PollingChangeWatcher(directory: directory, interval: .milliseconds(50)).changes()
        #expect(await nextChange(of: quiet, within: .milliseconds(400)) == false)

        let missing = PollingChangeWatcher(directory: directory.appendingPathComponent("nope"), interval: .milliseconds(50)).changes()
        #expect(await nextChange(of: missing, within: .milliseconds(300)) == false)
        #expect(PollingChangeWatcher.fingerprint(of: directory.appendingPathComponent("nope")).isEmpty)
    }

    @Test func aTriggerMakesTheLoopReadSoonerThanTheTimer() async throws {
        let script = ScriptedFetch([agents(summary("a", .working)), agents(summary("a", .blocked))])
        let store = SessionStore(fetch: { try await script.next() })
        let trigger = ManualTrigger()
        // A timer far longer than the test: only the trigger can cause the second read.
        let loop = RefreshLoop(activeInterval: .seconds(600), idleInterval: .seconds(600), debounce: .milliseconds(20))
        let running = Task { await loop.run(store: store, triggers: [trigger]) }
        defer { running.cancel() }

        while await script.calls < 1 || !trigger.isObserved { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await store.snapshot.waitingCount == 0)

        trigger.fire()
        let deadline = ContinuousClock.now + .seconds(5)
        while await script.calls < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await store.snapshot.waitingCount == 1)
    }

    @Test func pollsSlowlyOnlyWhenEverythingIsFinished() {
        let loop = RefreshLoop(activeInterval: .seconds(10), idleInterval: .seconds(60))
        var snapshot = StoreSnapshot()
        #expect(loop.interval(for: snapshot) == .seconds(60))
        snapshot.sessions = [Session(summary: summary("a", .done))]
        #expect(loop.interval(for: snapshot) == .seconds(60))
        snapshot.sessions.append(Session(summary: summary("b", .working)))
        #expect(loop.interval(for: snapshot) == .seconds(10))
        snapshot.sessions = [Session(summary: summary("c", .blocked))]
        #expect(loop.interval(for: snapshot) == .seconds(10))
        snapshot.sessions = []
        snapshot.problem = .timedOut
        #expect(loop.interval(for: snapshot) == .seconds(10))
    }

    @Test func aWatchLineIsOneLineOfJSONWithTheChanges() throws {
        var snapshot = StoreSnapshot()
        let blocked = Session(summary: summary("a", .blocked, name: "multi\nline name"))
        snapshot.sessions = [blocked]
        let update = StoreUpdate(snapshot: snapshot, events: [.appeared(blocked), .becameBlocked(blocked), .removed(id: "z")])

        let line = try WatchLine(update: update, isFirst: true).json()
        #expect(!line.contains("\n"))
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["event"] as? String == "snapshot")
        #expect(object["stale"] as? Bool == false)
        let changes = try #require(object["changes"] as? [[String: String]])
        #expect(changes.map { "\($0["kind"] ?? "") \($0["id"] ?? "")" } == ["appeared a", "becameBlocked a", "removed z"])
        #expect((object["status"] as? [String: Any])?["waiting"] as? Int == 1)

        let later = try WatchLine(update: StoreUpdate(snapshot: snapshot, events: []), isFirst: false).json()
        #expect(later.contains(#""event":"update""#))
    }
}
