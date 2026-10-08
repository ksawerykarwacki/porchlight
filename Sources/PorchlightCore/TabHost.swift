import Foundation

/// How the app asks a running `porchlight tab` to show a session: two small files in Porchlight's
/// own state folder. Nothing here talks to Claude Code; the host only starts documented commands.
public struct TabChannel: Sendable {
    public struct Host: Codable, Sendable, Equatable {
        public let pid: Int32
        public let startedAt: Date
    }

    private struct Request: Codable {
        let sessionID: String
        let requestedAt: Date
    }

    public let directory: URL

    public init(directory: URL = PorchlightPaths.stateDirectory().appendingPathComponent("tab", isDirectory: true)) {
        self.directory = directory
    }

    private var hostFile: URL { directory.appendingPathComponent("host.json") }
    private var requestFile: URL { directory.appendingPathComponent("request.json") }

    // MARK: Host side

    public func announce(pid: Int32, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: requestFile)
        try JSONEncoder().encode(Host(pid: pid, startedAt: now)).write(to: hostFile, options: .atomic)
    }

    /// Removes the announcement, but only if it is still this host's.
    public func withdraw(pid: Int32) {
        guard let host = readHost(), host.pid == pid else { return }
        try? FileManager.default.removeItem(at: hostFile)
        try? FileManager.default.removeItem(at: requestFile)
    }

    /// Takes the pending request, if any. Returns nil for anything that is not a plain session id.
    public func takeRequest() -> String? {
        guard let data = try? Data(contentsOf: requestFile) else { return nil }
        try? FileManager.default.removeItem(at: requestFile)
        guard let request = try? JSONDecoder().decode(Request.self, from: data), Self.isSessionID(request.sessionID) else {
            return nil
        }
        return request.sessionID
    }

    // MARK: App side

    private func readHost() -> Host? {
        guard let data = try? Data(contentsOf: hostFile) else { return nil }
        return try? JSONDecoder().decode(Host.self, from: data)
    }

    /// The announced host, if its process still exists.
    public func liveHost(isAlive: (Int32) -> Bool = TabChannel.processExists) -> Host? {
        guard let host = readHost(), isAlive(host.pid) else { return nil }
        return host
    }

    public func request(sessionID: String, now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(Request(sessionID: sessionID, requestedAt: now)).write(to: requestFile, options: .atomic)
    }

    public var hasPendingRequest: Bool { FileManager.default.fileExists(atPath: requestFile.path) }

    /// Asks the host for a session and waits for it to pick the request up. False means nobody is
    /// listening after all, and the request has been withdrawn.
    public func requestAndWait(sessionID: String, timeout: TimeInterval = 2) async -> Bool {
        guard (try? request(sessionID: sessionID)) != nil else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !hasPendingRequest { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? FileManager.default.removeItem(at: requestFile)
        return false
    }

    public static func processExists(_ pid: Int32) -> Bool {
        // Signal 0 only checks; EPERM still means the process is there.
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    /// Session ids and names reach a command line as one argument, but only plain ids are accepted
    /// from the request file at all.
    public static func isSessionID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}

/// The terminal's settings as they were before a full-screen program took over.
public struct TerminalState {
    private var saved: termios?

    /// Captures the terminal on standard input, or nothing when there is no terminal.
    public static func capture() -> TerminalState {
        var state = TerminalState()
        var attributes = termios()
        if isatty(STDIN_FILENO) == 1, tcgetattr(STDIN_FILENO, &attributes) == 0 {
            state.saved = attributes
        }
        return state
    }

    /// Puts the settings back. After a program that was stopped mid-screen, also undoes what it
    /// switched on: the alternate screen, hidden cursor, mouse reporting and bracketed paste.
    public func restore(afterForcedStop: Bool) {
        guard var attributes = saved else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        if afterForcedStop {
            let reset = "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1004l\u{1B}[?2004l\u{1B}[<u\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l"
            FileHandle.standardOutput.write(Data(reset.utf8))
        }
    }
}

/// Keeps one terminal tab showing Claude Code: agent view by default, and whichever session the
/// app asks for. Leaving a session returns to agent view; quitting agent view ends the host.
///
/// It only starts and stops the documented `claude agents` and `claude attach <id>` commands.
public struct TabHost {
    public struct Commands: Sendable {
        public var agentView: [String]
        public var attach: @Sendable (String) -> [String]

        public init(agentView: [String], attach: @escaping @Sendable (String) -> [String]) {
            self.agentView = agentView
            self.attach = attach
        }

        public static func claude(_ path: String) -> Commands {
            Commands(agentView: [path, "agents"], attach: { [path, "attach", $0] })
        }
    }

    enum Mode: Equatable {
        case agentView
        case attach(String)
    }

    public let channel: TabChannel
    public let commands: Commands
    public var pollInterval: TimeInterval = 0.15
    /// How long a stopped program gets to exit before it is killed.
    public var stopGrace: TimeInterval = 3

    public init(channel: TabChannel = TabChannel(), commands: Commands) {
        self.channel = channel
        self.commands = commands
    }

    public enum HostError: Error, Equatable {
        case couldNotStart(command: String, code: Int32)
    }

    /// Runs until the user quits agent view. Returns agent view's exit status.
    public func run() throws -> Int32 {
        let pid = ProcessInfo.processInfo.processIdentifier
        try channel.announce(pid: pid)
        defer { channel.withdraw(pid: pid) }
        let terminal = TerminalState.capture()

        var mode = Mode.agentView
        while true {
            let arguments = mode == .agentView ? commands.agentView : commands.attach(sessionID(of: mode))
            let child = try Self.spawn(arguments)

            var requested: String?
            var status: Int32?
            while status == nil {
                status = Self.exitStatus(of: child)
                if status == nil, let sessionID = channel.takeRequest() {
                    requested = sessionID
                    status = stop(child)
                    break
                }
                if status == nil { Thread.sleep(forTimeInterval: pollInterval) }
            }
            // `claude attach` does not tidy the terminal when it is stopped by a signal.
            terminal.restore(afterForcedStop: requested != nil)

            if let requested {
                mode = .attach(requested)
            } else if mode == .agentView {
                return status ?? 0
            } else {
                mode = .agentView
            }
        }
    }

    private func sessionID(of mode: Mode) -> String {
        if case .attach(let id) = mode { return id }
        return ""
    }

    /// Starts a child that shares this process's terminal, session and process group, so it is in
    /// the foreground exactly as if the user had typed the command. Foundation's `Process` is not
    /// used here: a full-screen program started through it drew nothing and exited at once.
    static func spawn(_ arguments: [String]) throws -> pid_t {
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        // The child starts with default signal handling and nothing blocked, whatever this
        // process inherited or set up; otherwise it might ignore the signal that stops it.
        var attributes = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        var noSignal = sigset_t()
        sigemptyset(&noSignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let code = posix_spawn(&pid, arguments[0], nil, &attributes, argv, environ)
        guard code == 0 else { throw HostError.couldNotStart(command: arguments[0], code: code) }
        return pid
    }

    /// The child's exit status if it has ended: its exit code, or 128 plus the signal number.
    static func exitStatus(of pid: pid_t, wait: Bool = false) -> Int32? {
        var raw: Int32 = 0
        let result = waitpid(pid, &raw, wait ? 0 : WNOHANG)
        if result == 0 { return nil }
        guard result == pid else { return 0 }
        let signal = raw & 0x7F
        return signal == 0 ? (raw >> 8) & 0xFF : 128 + signal
    }

    private func stop(_ pid: pid_t) -> Int32 {
        kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(stopGrace)
        while Date() < deadline {
            if let status = Self.exitStatus(of: pid) { return status }
            Thread.sleep(forTimeInterval: 0.02)
        }
        kill(pid, SIGKILL)
        return Self.exitStatus(of: pid, wait: true) ?? 0
    }
}
