import Foundation

/// A session the user keeps on purpose: a long-running thread, not something to finish and
/// clear away. Kept in Porchlight's own state; `claude agents --json` reports no pin of its own.
public struct Pin: Codable, Sendable, Equatable {
    public var since: Date
    /// When true the session's reminders are off and it does not light the lantern: for a
    /// session whose normal state is waiting for the next thing to do.
    public var quiet: Bool

    public init(since: Date, quiet: Bool = false) {
        self.since = since
        self.quiet = quiet
    }
}

/// The pinned sessions, by session id. A missing or broken file means none.
public struct Pins: Codable, Sendable, Equatable {
    public private(set) var sessions: [String: Pin]

    public init(sessions: [String: Pin] = [:]) {
        self.sessions = sessions
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var read: [String: Pin] = [:]
        // One pin at a time, so one odd entry does not unpin everything else.
        if let entries = try? c.nestedContainer(keyedBy: Key.self, forKey: .sessions) {
            for key in entries.allKeys {
                if let pin = try? entries.decode(Pin.self, forKey: key) { read[key.stringValue] = pin }
            }
        }
        sessions = read
    }

    public func isPinned(_ id: String) -> Bool { sessions[id] != nil }

    /// Sessions whose reminders are off because of their pin.
    public var quiet: Set<String> { Set(sessions.filter(\.value.quiet).keys) }

    public mutating func pin(_ id: String, quiet: Bool = false, now: Date = Date()) {
        // Pinning again keeps the date and only changes whether it is quiet.
        sessions[id] = Pin(since: sessions[id]?.since ?? now, quiet: quiet)
    }

    public mutating func unpin(_ id: String) {
        sessions[id] = nil
    }

    public static func fileURL(in stateDirectory: URL = PorchlightPaths.stateDirectory()) -> URL {
        stateDirectory.appendingPathComponent("pins.json")
    }

    public static func load(from url: URL = Pins.fileURL()) -> Pins {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let pins = try? decoder.decode(Pins.self, from: data) else { return Pins() }
        return pins
    }

    public func save(to url: URL = Pins.fileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
