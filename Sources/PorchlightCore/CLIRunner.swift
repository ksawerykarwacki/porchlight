import Foundation

public struct CLIResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CLIError: Error, Sendable, Equatable {
    case launchFailed(String)
    case timedOut(after: TimeInterval)
}

/// Runs an executable with an argv array (never a shell string), a working directory and a timeout.
public struct CLIRunner: Sendable {
    public init() {}

    public func run(
        _ executable: URL,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        input: String? = nil,
        timeout: TimeInterval = 15
    ) async throws -> CLIResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try Self.runBlocking(executable, arguments, cwd: cwd, environment: environment, input: input, timeout: timeout)
                })
            }
        }
    }

    private static func runBlocking(
        _ executable: URL,
        _ arguments: [String],
        cwd: URL?,
        environment: [String: String]?,
        input: String?,
        timeout: TimeInterval
    ) throws -> CLIResult {
        // Output goes to temp files, not pipes: `claude --bg` can leave a daemon holding the
        // inherited descriptors open, which would block a pipe reader long after the CLI exits.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("porchlight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let outURL = scratch.appendingPathComponent("stdout")
        let errURL = scratch.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        if let environment { process.environment = environment }
        if let input {
            let inURL = scratch.appendingPathComponent("stdin")
            try Data(input.utf8).write(to: inURL)
            process.standardInput = try FileHandle(forReadingFrom: inURL)
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        process.standardOutput = outHandle
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            throw CLIError.launchFailed(error.localizedDescription)
        }

        let watchdog = Watchdog(pid: process.processIdentifier)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { watchdog.fire() }
        process.waitUntilExit()
        if watchdog.finish() {
            throw CLIError.timedOut(after: timeout)
        }

        let stdout = String(decoding: (try? Data(contentsOf: outURL)) ?? Data(), as: UTF8.self)
        let stderr = String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        return CLIResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// Terminates a child once, unless the child has already been reaped.
private final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let pid: Int32
    private var finished = false
    private var fired = false

    init(pid: Int32) { self.pid = pid }

    func fire() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        fired = true
        kill(pid, SIGTERM)
    }

    /// Marks the child as reaped; returns whether the watchdog killed it.
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        finished = true
        return fired
    }
}
