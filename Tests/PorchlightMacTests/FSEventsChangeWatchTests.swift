import Foundation
import PorchlightCore
import PorchlightMac
import Testing

/// Waits for the next element of a stream, or gives up after a timeout.
func firstChange(of stream: AsyncStream<Void>, within timeout: Duration) async -> Bool {
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

@Suite struct FSEventsChangeWatchTests {
    func jobsDirectory() throws -> URL {
        // Resolved, because FSEvents reports /private/var for /var.
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("porchlight-fsevents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("11111111"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("11111111/state.json"))
        return directory
    }

    @Test func firesWhenAStateFileInASubdirectoryIsRewritten() async throws {
        let directory = try jobsDirectory()
        let stream = FSEventsChangeWatcher(directory: directory, latency: 0.1).changes()
        try await Task.sleep(for: .milliseconds(300))
        try Data(#"{"state":"blocked"}"#.utf8).write(to: directory.appendingPathComponent("11111111/state.json"))
        #expect(await firstChange(of: stream, within: .seconds(10)))
    }

    @Test func staysQuietWhenNothingChanges() async throws {
        let directory = try jobsDirectory()
        // Let the directory's own creation events age out before listening.
        try await Task.sleep(for: .seconds(1))
        let stream = FSEventsChangeWatcher(directory: directory, latency: 0.1).changes()
        #expect(await firstChange(of: stream, within: .seconds(1)) == false)
    }
}
