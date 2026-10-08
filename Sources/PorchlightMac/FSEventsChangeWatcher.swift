import CoreServices
import Foundation
import PorchlightCore

/// Notification-based trigger for macOS: fires when anything under a directory changes, including
/// rewrites of files in its subdirectories, without polling.
public struct FSEventsChangeWatcher: ChangeTrigger {
    public let directory: URL
    /// How long the system batches events before delivering them.
    public let latency: TimeInterval

    public init(
        directory: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/jobs"),
        latency: TimeInterval = 0.3
    ) {
        self.directory = directory
        self.latency = latency
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let box = Unmanaged.passRetained(ContinuationBox(continuation))
        var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ContinuationBox>.fromOpaque(info).takeUnretainedValue().continuation.yield()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let eventStream = FSEventStreamCreate(
            nil, callback, &context, [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            box.release()
            continuation.finish()
            return stream
        }
        FSEventStreamSetDispatchQueue(eventStream, DispatchQueue(label: "porchlight.fsevents"))
        FSEventStreamStart(eventStream)

        let handle = StreamHandle(stream: eventStream, box: box)
        continuation.onTermination = { _ in handle.stop() }
        return stream
    }
}

private final class ContinuationBox {
    let continuation: AsyncStream<Void>.Continuation
    init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
}

/// Owns the event stream and the retained callback context until the consumer goes away.
private final class StreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let box: Unmanaged<ContinuationBox>

    init(stream: FSEventStreamRef, box: Unmanaged<ContinuationBox>) {
        self.stream = stream
        self.box = box
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        box.release()
    }
}
