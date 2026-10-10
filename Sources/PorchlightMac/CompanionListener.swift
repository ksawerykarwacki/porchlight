import Foundation
import Network
import PorchlightCore

/// The app's end of the channel to the companion mod: a very small HTTP server on a Unix socket.
///
/// A Unix socket rather than a port: nothing on the network, no browser and no other user can
/// reach it. Every request must also carry the secret from a file only the owner can read.
///
///   POST /v1/event              one report; its body is handed to the hub
///   GET  /v1/next?session=<id>  held open until there is a command for that session, or the
///                               hold runs out (then 204, and the mod asks again)
///
/// Nothing is sent to a session in this layer: the command queue exists so that the mod's side
/// of the conversation does not have to change when something is.
public final class CompanionListener: @unchecked Sendable {
    public enum StartFailure: Error, Equatable {
        /// The socket's path is longer than the system allows.
        case pathTooLong
        /// Another running copy of the app already answers on the socket.
        case alreadyRunning
        case couldNotListen(String)
    }

    public let paths: CompanionPaths
    private let hub: CompanionHub
    /// What every request must carry. Made, and written for the mod to find, when listening starts.
    public private(set) var secret = ""
    private let hold: TimeInterval
    private let queue = DispatchQueue(label: "porchlight.companion")
    private var listener: NWListener?
    /// Requests being held, and commands waiting for one, by short session id.
    private var held: [String: [(id: UUID, connection: NWConnection)]] = [:]
    private var commands: [String: [(data: Data, queuedAt: Date)]] = [:]
    /// A command nobody asked for within this time is dropped: the question it answered is gone.
    private let commandLifetime: TimeInterval

    static let bodyLimit = 256 * 1024
    static let headerLimit = 16 * 1024

    public init(paths: CompanionPaths = CompanionPaths(), hub: CompanionHub, hold: TimeInterval = 25, commandLifetime: TimeInterval = 60) {
        self.commandLifetime = commandLifetime
        self.paths = paths
        self.hub = hub
        self.hold = hold
    }

    /// Starts listening. A socket file left by a copy that is gone is replaced; one that a
    /// running copy answers on is left alone.
    public func start() throws {
        guard paths.socketPathFits else { throw StartFailure.pathTooLong }
        let path = paths.socket.path
        if FileManager.default.fileExists(atPath: path) {
            guard !Self.isAnswering(path) else { throw StartFailure.alreadyRunning }
            try? FileManager.default.removeItem(atPath: path)
        }
        // Only now, with no other copy answering: a second copy must not replace the secret the
        // first one's sessions are using.
        do {
            secret = try paths.writeDescriptor()
        } catch {
            throw StartFailure.couldNotListen("the file that tells the mod where the app is could not be written")
        }
        // The folder the socket is made in is closed to everyone else first. The socket file is
        // only given its own mode once it exists, and the process-wide mask is not touched for
        // it: that would change the mode of every file another thread makes in the meantime.
        let folder = paths.socket.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartFailure.couldNotListen(error.localizedDescription)
        }
        let ready = DispatchSemaphore(value: 0)
        let failure = Failure()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error):
                failure.text = error.localizedDescription
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, failure.text == nil else {
            listener.cancel()
            throw StartFailure.couldNotListen(failure.text ?? "the socket did not come up")
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            listener.cancel()
            throw StartFailure.couldNotListen("the socket could not be closed to other users")
        }
        self.listener = listener
    }

    /// Stops listening and removes what a mod would look for.
    public func stop() {
        guard listener != nil else { return }
        paths.removeDescriptor()
        queue.sync {
            listener?.cancel()
            listener = nil
            held.values.joined().forEach { $0.connection.cancel() }
            held = [:]
        }
        try? FileManager.default.removeItem(at: paths.socket)
    }

    /// How many requests are being held for a session, for tests that must not send too early.
    func heldCount(for session: String) -> Int {
        queue.sync { held[Self.key(session)]?.count ?? 0 }
    }

    /// Hands a command to a session's mod. True when the mod was waiting and has it now; false
    /// when it was queued for the mod's next request, which may never come.
    @discardableResult
    public func send(_ command: Data, to session: String) -> Bool {
        queue.sync {
            let key = Self.key(session)
            if var waiting = self.held[key], !waiting.isEmpty {
                let first = waiting.removeFirst()
                self.held[key] = waiting
                self.respond(first.connection, status: 200, body: command)
                return true
            }
            self.commands[key, default: []].append((command, Date()))
            return false
        }
    }

    private final class Failure: @unchecked Sendable {
        var text: String?
    }

    /// True when something accepts connections on the socket at this path.
    static func isAnswering(_ path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) == 0 }
        }
    }

    static func key(_ session: String) -> String {
        String(session.lowercased().prefix(36))
    }

    // MARK: One request per connection

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, collected: Data())
    }

    private func read(_ connection: NWConnection, collected: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var collected = collected
            if let data { collected.append(data) }
            if let request = Request(collected) {
                self.handle(request, on: connection)
            } else if error != nil || isComplete || collected.count > Self.headerLimit + Self.bodyLimit {
                connection.cancel()
            } else {
                self.read(connection, collected: collected)
            }
        }
    }

    /// A request, once all of it has arrived. Only what the mod sends is understood: a request
    /// line, headers, and a body whose length is given.
    struct Request {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data

        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)), end.lowerBound <= CompanionListener.headerLimit,
                  let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count >= 2 else { return nil }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            guard length >= 0, length <= CompanionListener.bodyLimit else { return nil }
            let bodyStart = end.upperBound
            guard data.count - data.distance(from: data.startIndex, to: bodyStart) >= length else { return nil }
            let target = String(first[1])
            let parts = target.split(separator: "?", maxSplits: 1)
            var query: [String: String] = [:]
            if parts.count == 2 {
                for pair in parts[1].split(separator: "&") {
                    let sides = pair.split(separator: "=", maxSplits: 1)
                    if sides.count == 2 { query[String(sides[0])] = String(sides[1]).removingPercentEncoding ?? String(sides[1]) }
                }
            }
            method = String(first[0])
            path = parts.first.map(String.init) ?? target
            self.query = query
            self.headers = headers
            body = data.subdata(in: bodyStart..<data.index(bodyStart, offsetBy: length))
        }
    }

    private func handle(_ request: Request, on connection: NWConnection) {
        guard Self.matches(request.headers["x-porchlight-secret"] ?? "", secret) else {
            respond(connection, status: 403)
            return
        }
        switch (request.method, request.path) {
        case ("POST", "/v1/event"):
            // 422 for a report this build does not understand: the mod then knows not to count on it.
            respond(connection, status: hub.receive(request.body) == nil ? 422 : 204)
        case ("GET", "/v1/next"):
            guard let session = request.query["session"], WrapUp.isValidConversationID(session) else {
                respond(connection, status: 400)
                return
            }
            hold(connection, for: Self.key(session))
        default:
            respond(connection, status: 404)
        }
    }

    private func hold(_ connection: NWConnection, for key: String) {
        commands[key]?.removeAll { Date().timeIntervalSince($0.queuedAt) > commandLifetime }
        if var waiting = commands[key], !waiting.isEmpty {
            let command = waiting.removeFirst()
            commands[key] = waiting
            respond(connection, status: 200, body: command.data)
            return
        }
        let id = UUID()
        held[key, default: []].append((id, connection))
        queue.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, let index = self.held[key]?.firstIndex(where: { $0.id == id }) else { return }
            self.held[key]?.remove(at: index)
            self.respond(connection, status: 204)
        }
    }

    private func respond(_ connection: NWConnection, status: Int, body: Data = Data()) {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 422: "Unprocessable Content"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    /// Compares without stopping at the first difference.
    static func matches(_ given: String, _ expected: String) -> Bool {
        let (a, b) = (Array(given.utf8), Array(expected.utf8))
        guard a.count == b.count, !b.isEmpty else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
