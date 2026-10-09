import Foundation
import Testing

@testable import PorchlightCore

@Suite struct TabHostTests {
    func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-tab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }

    func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Stand-ins for claude: "agent view" runs until told to quit, "attach" runs until its
    /// session's file appears (the user leaving) or it is stopped.
    func commands(log: URL, directory: URL) -> TabHost.Commands {
        let quit = directory.appendingPathComponent("quit").path
        return TabHost.Commands(
            agentView: ["/bin/sh", "-c", "echo agents >> '\(log.path)'; while [ ! -e '\(quit)' ]; do sleep 0.05; done; exit 7"],
            attach: { id in
                ["/bin/sh", "-c", "echo attach \(id) >> '\(log.path)'; while [ ! -e '\(directory.path)/leave-\(id)' ]; do sleep 0.05; done"]
            })
    }

    @Test func swapsToARequestedSessionAndReturnsToAgentViewWhenItIsLeft() async throws {
        let directory = try scratch()
        let log = directory.appendingPathComponent("log")
        let channel = TabChannel(directory: directory.appendingPathComponent("tab"))
        var host = TabHost(channel: channel, commands: commands(log: log, directory: directory))
        host.pollInterval = 0.02
        let hostCopy = host
        let running = Task.detached { try hostCopy.run() }

        #expect(await waitUntil { lines(log) == ["agents"] })
        #expect(channel.liveHost()?.pid == ProcessInfo.processInfo.processIdentifier)

        // The app asks for a session: agent view is stopped and the session takes the tab.
        #expect(await channel.requestAndWait(sessionID: "aaaa1111"))
        #expect(await waitUntil { lines(log) == ["agents", "attach aaaa1111"] })

        // Asking for another while one is showing swaps straight to it.
        #expect(await channel.requestAndWait(sessionID: "bbbb2222"))
        #expect(await waitUntil { lines(log) == ["agents", "attach aaaa1111", "attach bbbb2222"] })

        // The user leaves the session: back to agent view.
        FileManager.default.createFile(atPath: directory.appendingPathComponent("leave-bbbb2222").path, contents: nil)
        #expect(await waitUntil { lines(log) == ["agents", "attach aaaa1111", "attach bbbb2222", "agents"] })

        // The user quits agent view: the host ends with its status and withdraws.
        FileManager.default.createFile(atPath: directory.appendingPathComponent("quit").path, contents: nil)
        #expect(try await running.value == 7)
        #expect(channel.liveHost() == nil)
        #expect(lines(log).count == 4)
    }

    /// The host does not find out by looking every so often: with ten seconds between looks it
    /// still follows a request and a session being left at once.
    @Test func theHostIsWokenByARequestAndByItsProgramEnding() async throws {
        let directory = try scratch()
        let log = directory.appendingPathComponent("log")
        let channel = TabChannel(directory: directory.appendingPathComponent("tab"))
        var host = TabHost(channel: channel, commands: commands(log: log, directory: directory))
        host.pollInterval = 10
        let running = Task.detached { [host] in try host.run() }
        #expect(await waitUntil(5) { lines(log) == ["agents"] && channel.liveHost() != nil })

        var started = Date()
        try channel.request(sessionID: "4cb41c2a")
        #expect(await waitUntil(5) { lines(log) == ["agents", "attach 4cb41c2a"] })
        #expect(Date().timeIntervalSince(started) < 2)

        started = Date()
        FileManager.default.createFile(atPath: directory.appendingPathComponent("leave-4cb41c2a").path, contents: nil)
        #expect(await waitUntil(5) { lines(log) == ["agents", "attach 4cb41c2a", "agents"] })
        #expect(Date().timeIntervalSince(started) < 2)

        started = Date()
        FileManager.default.createFile(atPath: directory.appendingPathComponent("quit").path, contents: nil)
        #expect(try await running.value == 7)
        #expect(Date().timeIntervalSince(started) < 2)

        // A child that is already gone, or a folder that is not there, never makes it wait long.
        started = Date()
        TabHost.wait(forExitOf: 1_999_999, orChangeIn: directory.appendingPathComponent("nowhere"), atMost: 0.2)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func ignoresRequestsThatAreNotPlainSessionIDs() async throws {
        let directory = try scratch()
        let channel = TabChannel(directory: directory)
        try channel.request(sessionID: "x; rm -rf /")
        #expect(channel.takeRequest() == nil)
        #expect(!channel.hasPendingRequest)
        try channel.request(sessionID: "4cb41c2a")
        #expect(channel.takeRequest() == "4cb41c2a")
        #expect(channel.takeRequest() == nil)
        #expect(TabChannel.isSessionID("a1b2c3d4-0000-4000-8000-000000000000"))
        #expect(!TabChannel.isSessionID(""))
        #expect(!TabChannel.isSessionID("../etc"))
        #expect(!TabChannel.isSessionID("--help x"))
    }

    @Test func aHostThatIsGoneIsNotLiveAndARequestToItTimesOut() async throws {
        let directory = try scratch()
        let channel = TabChannel(directory: directory)
        #expect(channel.liveHost() == nil)

        try channel.announce(pid: 4242)
        #expect(channel.liveHost(isAlive: { _ in false }) == nil)
        #expect(channel.liveHost(isAlive: { $0 == 4242 })?.pid == 4242)

        // Nobody takes the request: it is withdrawn so it cannot fire later.
        #expect(await channel.requestAndWait(sessionID: "aaaa1111", timeout: 0.2) == false)
        #expect(!channel.hasPendingRequest)

        // Withdrawing is a no-op for a different host.
        channel.withdraw(pid: 1)
        #expect(channel.liveHost(isAlive: { _ in true })?.pid == 4242)
        channel.withdraw(pid: 4242)
        #expect(channel.liveHost(isAlive: { _ in true }) == nil)
        #expect(TabChannel.processExists(ProcessInfo.processInfo.processIdentifier))
        #expect(!TabChannel.processExists(0))
    }

    @Test func buildsTheDocumentedClaudeCommands() {
        let commands = TabHost.Commands.claude("/Users/u/.local/bin/claude")
        #expect(commands.agentView == ["/Users/u/.local/bin/claude", "agents"])
        #expect(commands.attach("4cb41c2a") == ["/Users/u/.local/bin/claude", "attach", "4cb41c2a"])
    }
}
