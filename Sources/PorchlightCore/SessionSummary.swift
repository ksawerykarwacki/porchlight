import Foundation

/// Session state as reported by `claude agents --json`. Unknown values are kept, never rejected.
public enum SessionState: Sendable, Hashable {
    case working
    case blocked
    case done
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "working": self = .working
        case "blocked": self = .blocked
        case "done": self = .done
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .working: "working"
        case .blocked: "blocked"
        case .done: "done"
        case .unknown(let value): value
        }
    }
}

/// One element of `claude agents --json [--all]`: the official, supported view of a session.
public struct SessionSummary: Sendable, Equatable, Decodable {
    public let id: String
    public let sessionId: String?
    public let name: String
    public let cwd: String
    public let kind: String?
    /// The source of truth for whether a session needs the human. `status` can disagree with it.
    public let state: SessionState
    public let status: String?
    /// A category such as "permission prompt" or "input needed"; never the question text.
    public let waitingFor: String?
    public let startedAt: Date?
    public let pid: Int?

    public init(
        id: String, sessionId: String? = nil, name: String = "", cwd: String = "", kind: String? = nil,
        state: SessionState, status: String? = nil, waitingFor: String? = nil, startedAt: Date? = nil,
        pid: Int? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.state = state
        self.status = status
        self.waitingFor = waitingFor
        self.startedAt = startedAt
        self.pid = pid
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionId, name, cwd, kind, state, status, waitingFor, startedAt, pid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Only `id` is required; everything else degrades instead of failing the row.
        id = try c.decode(String.self, forKey: .id)
        sessionId = try? c.decodeIfPresent(String.self, forKey: .sessionId)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        cwd = (try? c.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        state = SessionState(rawValue: (try? c.decodeIfPresent(String.self, forKey: .state)) ?? "")
        status = try? c.decodeIfPresent(String.self, forKey: .status)
        waitingFor = try? c.decodeIfPresent(String.self, forKey: .waitingFor)
        let millis = try? c.decodeIfPresent(Double.self, forKey: .startedAt)
        startedAt = millis.map { Date(timeIntervalSince1970: $0 / 1000) }
        pid = try? c.decodeIfPresent(Int.self, forKey: .pid)
    }
}

/// Decodes an array element by element, skipping elements that fail instead of failing the lot.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var skipped = 0

    private struct Skip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                _ = try? container.decode(Skip.self)
                skipped += 1
            }
        }
    }
}
