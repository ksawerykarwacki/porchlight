import Foundation
import Testing

@testable import PorchlightCore
@testable import PorchlightMac
@testable import PorchlightUI

private let conversation = "22222222-0000-4000-8000-000000000000"

/// A listener on a socket of its own, and `curl` to speak to it the way the mod's engine does.
final class CompanionRig: @unchecked Sendable {
    let directory: URL
    let paths: CompanionPaths
    let hub = CompanionHub()
    let listener: CompanionListener
    var secret: String { listener.secret }

    init(hold: TimeInterval = 25) throws {
        // Short on purpose: a socket's path may only be 103 bytes long.
        directory = URL(fileURLWithPath: "/tmp/pl-\(UUID().uuidString.prefix(8))")
        paths = CompanionPaths(directory: directory)
        listener = CompanionListener(paths: paths, hub: hub, hold: hold)
        try listener.start()
    }

    deinit {
        listener.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// The status and body of one request. `secret` nil sends none.
    func request(_ method: String, _ path: String, body: String? = nil, secret: String?? = .none, timeout: TimeInterval = 10) async throws -> (status: Int, body: String) {
        var arguments = ["-s", "--unix-socket", paths.socket.path, "-X", method, "-w", "\n%{http_code}", "--max-time", String(Int(timeout))]
        let sent: String? = switch secret {
        case .none: self.secret
        case .some(let given): given
        }
        if let sent { arguments += ["-H", "X-Porchlight-Secret: \(sent)"] }
        if let body { arguments += ["-H", "Content-Type: application/json", "--data-binary", body] }
        arguments.append("http://porchlight\(path)")
        let result = try await CLIRunner().run(URL(fileURLWithPath: "/usr/bin/curl"), arguments, timeout: timeout + 5)
        let lines = result.stdout.components(separatedBy: "\n")
        return (Int(lines.last ?? "") ?? 0, lines.dropLast().joined(separator: "\n"))
    }

    func event(_ fields: [String: Any]) -> String {
        var all: [String: Any] = ["v": 1, "session": conversation]
        fields.forEach { all[$0] = $1 }
        return String(decoding: try! JSONSerialization.data(withJSONObject: all), as: UTF8.self)
    }
}

@Suite struct CompanionListenerTests {
    @Test func theSocketIsItsOwnersAloneAndAReportIsDelivered() async throws {
        let rig = try CompanionRig()
        let mode = try #require(FileManager.default.attributesOfItem(atPath: rig.paths.socket.path)[.posixPermissions] as? NSNumber)
        #expect(mode.intValue == 0o600)

        let delivered = try await rig.request("POST", "/v1/event", body: rig.event(["kind": "permission", "tool": "Bash", "detail": "make deploy"]))
        #expect(delivered.status == 204)
        #expect(rig.hub.snapshot()[conversation]?.waiting == .permission(tool: "Bash", detail: "make deploy"))
        // A report this build does not understand is said to be so, and changes nothing.
        let unknown = try await rig.request("POST", "/v1/event", body: rig.event(["kind": "something.new"]))
        #expect(unknown.status == 422 && rig.hub.reportCount == 1)
        #expect(try await rig.request("GET", "/v1/elsewhere").status == 404)
        #expect(try await rig.request("GET", "/v1/next?session=not-an-id").status == 400)
    }

    @Test func nothingGetsInWithoutTheSecret() async throws {
        let rig = try CompanionRig()
        let report = rig.event(["kind": "turn.start"])
        #expect(try await rig.request("POST", "/v1/event", body: report, secret: .some(nil)).status == 403)
        #expect(try await rig.request("POST", "/v1/event", body: report, secret: .some("wrong")).status == 403)
        #expect(try await rig.request("POST", "/v1/event", body: report, secret: .some(String(rig.secret.dropLast()) + "0")).status == 403)
        #expect(try await rig.request("GET", "/v1/next?session=\(conversation)", secret: .some("")).status == 403)
        #expect(rig.hub.reportCount == 0 && rig.hub.snapshot().isEmpty)
        #expect(!CompanionListener.matches("", "") && !CompanionListener.matches("ab", "abc") && CompanionListener.matches("abc", "abc"))
    }

    @Test func aHeldRequestReturnsWhenItsTimeIsUpOrACommandComes() async throws {
        let rig = try CompanionRig(hold: 0.6)
        var started = Date()
        let empty = try await rig.request("GET", "/v1/next?session=\(conversation)")
        let waited = Date().timeIntervalSince(started)
        #expect(empty.status == 204 && empty.body.isEmpty && waited > 0.4 && waited < 5)

        // A command queued before the mod asks is there when it does.
        rig.listener.send(Data(#"{"type":"note","text":"hello"}"#.utf8), to: conversation)
        let queued = try await rig.request("GET", "/v1/next?session=\(conversation)")
        #expect(queued.status == 200 && queued.body == #"{"type":"note","text":"hello"}"#)

        // One sent while the request is held ends the hold at once, and only for that session.
        let slow = try CompanionRig(hold: 20)
        started = Date()
        async let answer = slow.request("GET", "/v1/next?session=\(conversation)", timeout: 15)
        try await Task.sleep(for: .milliseconds(400))
        slow.listener.send(Data(#"{"type":"other"}"#.utf8), to: "33333333-0000-4000-8000-000000000000")
        slow.listener.send(Data(#"{"type":"mine"}"#.utf8), to: conversation.uppercased())
        let got = try await answer
        #expect(got.status == 200 && got.body == #"{"type":"mine"}"# && Date().timeIntervalSince(started) < 8)
    }

    @Test func aSecondListenerReplacesADeadOneAndNotALiveOne() throws {
        let rig = try CompanionRig()
        let second = CompanionListener(paths: rig.paths, hub: CompanionHub())
        let written = try Data(contentsOf: rig.paths.descriptor)
        #expect(throws: CompanionListener.StartFailure.alreadyRunning) { try second.start() }
        // The copy that was refused left the running one's secret as it was.
        #expect(try Data(contentsOf: rig.paths.descriptor) == written && second.secret.isEmpty && rig.secret.count == 48)

        // The first one gone, leaving its file behind as a crash would: the next start takes over.
        rig.listener.stop()
        FileManager.default.createFile(atPath: rig.paths.socket.path, contents: nil)
        #expect(!CompanionListener.isAnswering(rig.paths.socket.path))
        try second.start()
        #expect(CompanionListener.isAnswering(rig.paths.socket.path))
        #expect(second.secret.count == 48 && second.secret != rig.secret && FileManager.default.fileExists(atPath: rig.paths.descriptor.path))
        second.stop()
        #expect(!FileManager.default.fileExists(atPath: rig.paths.socket.path) && !FileManager.default.fileExists(atPath: rig.paths.descriptor.path))

        let deep = CompanionPaths(
            directory: URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 120)),
            fallbackDirectory: URL(fileURLWithPath: "/tmp/" + String(repeating: "b", count: 120)))
        #expect(throws: CompanionListener.StartFailure.pathTooLong) { try CompanionListener(paths: deep, hub: CompanionHub()).start() }
    }

    @Test func requestsArePartsOfOneUnderstoodShape() {
        let request = CompanionListener.Request(Data("POST /v1/event?a=1&b=two%20words HTTP/1.1\r\nHost: x\r\nX-Porchlight-Secret: abc\r\nContent-Length: 4\r\n\r\nbody".utf8))
        #expect(request?.method == "POST" && request?.path == "/v1/event" && request?.query == ["a": "1", "b": "two words"])
        #expect(request?.headers["x-porchlight-secret"] == "abc" && request?.body == Data("body".utf8))
        // Not all of it there yet, or more than is allowed: not a request.
        #expect(CompanionListener.Request(Data("POST /v1/event HTTP/1.1\r\nContent-Length: 10\r\n\r\nbody".utf8)) == nil)
        #expect(CompanionListener.Request(Data("POST /v1/event HTTP/1.1\r\nContent-Length: 4".utf8)) == nil)
        #expect(CompanionListener.Request(Data("POST /v1/event HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) == nil)
        #expect(CompanionListener.Request(Data("nonsense\r\n\r\n".utf8)) == nil)
    }
}

@MainActor
@Suite struct CompanionWiringTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    func report(_ fields: [String: Any]) -> Data {
        var all: [String: Any] = ["v": 1, "session": conversation]
        fields.forEach { all[$0] = $1 }
        return try! JSONSerialization.data(withJSONObject: all)
    }

    let listed = [SessionSummary(id: "22222222", sessionId: conversation, name: "asks", cwd: "/Users/u/code/app", kind: "background", state: .blocked)]
    let asked: [String: Any] = ["kind": "question", "questions": [["question": "Apple or pear?", "options": [["label": "apple"], ["label": "pear"]]]]]

    @Test func aReportMakesTheStoreReadAgainAtOnce() async throws {
        let hub = CompanionHub()
        let reads = Counter()
        let listed = listed
        let store = SessionStore(
            fetch: {
                reads.bump()
                return AgentsSnapshot(sessions: listed, skipped: 0)
            }, companion: { hub.snapshot() })
        // A minute between reads on the timer: anything sooner is the trigger's doing.
        let loop = Task { await RefreshLoop(activeInterval: .seconds(60), idleInterval: .seconds(60), debounce: .milliseconds(20)).run(store: store, triggers: [hub]) }
        defer { loop.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while reads.count < 1, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let before = reads.count
        #expect(before >= 1)

        hub.receive(report(asked))
        while reads.count == before, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(reads.count > before)
        #expect(await store.snapshot.sessions.first?.questions.map(\.question) == ["Apple or pear?"])
    }

    @Test func theFactsReachTheInboxAndGoneSessionsAreForgotten() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-companion-wiring-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hub = CompanionHub()
        hub.receive(report(asked))
        hub.receive(report(["kind": "turn.start", "session": "99999999-0000-4000-8000-000000000000"]))
        let listed = listed
        let store = SessionStore(fetch: { AgentsSnapshot(sessions: listed, skipped: 0) }, companion: { hub.snapshot() })
        let inbox = InboxModel(store: store, settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory), companion: hub)
        #expect(inbox.listensForCompanion && inbox.companionSessions == 0)
        await store.refresh()
        inbox.apply(await store.snapshot)

        #expect(inbox.companionSessions == 1)
        let session = try #require(inbox.snapshot.sessions.first)
        #expect(session.questions.map(\.question) == ["Apple or pear?"] && session.questions[0].options.map(\.label) == ["apple", "pear"])
        // The session that is not on the list is forgotten; the one that is stays.
        #expect(Array(hub.snapshot().keys) == [conversation])

        // A read that failed says nothing about which sessions exist: nothing is forgotten on it.
        hub.receive(report(["kind": "turn.start", "session": "99999999-0000-4000-8000-000000000000"]))
        var failed = StoreSnapshot()
        failed.problem = .timedOut
        inbox.apply(failed)
        #expect(hub.snapshot().count == 2)
    }

    @Test func settingsSayWhetherTheModIsHeard() {
        #expect(InboxActions.companionStatus(listens: false, problem: nil, sessions: 0) == nil)
        #expect(InboxActions.companionStatus(listens: false, problem: "another copy of Porchlight is already listening.", sessions: 0)
            == "Not listening for the companion mod: another copy of Porchlight is already listening.")
        let none = InboxActions.companionStatus(listens: true, problem: nil, sessions: 0)
        #expect(none?.contains("It only reports") == true && none?.hasSuffix("/plugin install porchlight-companion --marketplace ksawerykarwacki/porchlight") == true)
        #expect(InboxActions.companionStatus(listens: true, problem: nil, sessions: 1)?.hasPrefix("1 session reports through") == true)
        #expect(InboxActions.companionStatus(listens: true, problem: nil, sessions: 3)?.hasPrefix("3 sessions report through") == true)
        // A model made without a hub, as in every other test, does not claim to listen.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-companion-none-\(UUID().uuidString)")
        let plain = InboxModel(settingsURL: Settings.fileURL(in: directory), remindersURL: ReminderState.fileURL(in: directory))
        #expect(!plain.listensForCompanion)
    }
}
