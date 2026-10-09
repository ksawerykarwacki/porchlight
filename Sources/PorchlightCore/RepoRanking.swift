import Foundation

/// The sessions most recently started from Porchlight: what to rank repositories by, and what
/// "repeat the last one" repeats. Prompts are not kept.
public struct DispatchHistory: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var directory: String
        public var name: String?
        public var model: String?
        public var date: Date

        public init(directory: String, name: String? = nil, model: String? = nil, date: Date) {
            self.directory = directory
            self.name = name
            self.model = model
            self.date = date
        }
    }

    public static let limit = 20

    /// Newest first.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = Array(entries.sorted { $0.date > $1.date }.prefix(Self.limit))
    }

    private enum CodingKeys: String, CodingKey {
        case entries
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Entries are read one by one, so one odd entry does not lose the rest.
        self.init(entries: ((try? c.decodeIfPresent(LossyArray<Entry>.self, forKey: .entries))?.elements) ?? [])
    }

    public var last: Entry? { entries.first }

    public mutating func record(_ entry: Entry) {
        self = DispatchHistory(entries: [entry] + entries)
    }

    /// How much a folder has been used: every dispatch counts, a recent one for more. One made
    /// just now counts 1, and half as much for every week since.
    public func frecency(of directory: String, now: Date) -> Double {
        entries.filter { $0.directory == directory }.reduce(0) { total, entry in
            let weeks = max(0, now.timeIntervalSince(entry.date)) / (7 * 86400)
            return total + pow(0.5, weeks)
        }
    }

    public static func fileURL(in stateDirectory: URL = PorchlightPaths.stateDirectory()) -> URL {
        stateDirectory.appendingPathComponent("dispatches.json")
    }

    public static func load(from url: URL = DispatchHistory.fileURL()) -> DispatchHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let history = try? decoder.decode(DispatchHistory.self, from: data) else {
            return DispatchHistory()
        }
        return history
    }

    public func save(to url: URL = DispatchHistory.fileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

/// Orders repositories for the picker.
public struct RepoRanking: Sendable {
    public var history: DispatchHistory
    public var now: Date
    public var home: String

    public init(history: DispatchHistory = DispatchHistory(), now: Date = Date(), home: String = NSHomeDirectory()) {
        self.history = history
        self.now = now
        self.home = home
    }

    /// How much a repository has been used: dispatches from Porchlight, plus a little for having
    /// sessions at all, which also covers sessions started elsewhere.
    public func use(of repo: Repo) -> Double {
        history.frecency(of: repo.path, now: now) + (repo.hasSessions ? 0.25 : 0)
    }

    /// With nothing typed: pinned, then most used, then by name. With text: the repositories that
    /// match, best match first, where being pinned or often used lifts a repository over others
    /// that match about as well.
    public func ranked(_ index: RepoIndex, query: String = "") -> [Repo] {
        let query = query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            return index.repos.sorted { a, b in
                if a.isPinned != b.isPinned { return a.isPinned }
                let useA = use(of: a), useB = use(of: b)
                return useA != useB ? useA > useB : RepoIndex.listOrder(a, b)
            }
        }
        let scored: [(repo: Repo, score: Double)] = index.repos.compactMap { repo in
            guard let match = FuzzyMatch.score(query, name: repo.name, path: repo.displayPath(home: home)) else { return nil }
            // Worth at most a few letters of match quality: use decides between near ties, and
            // never puts a poor match over a good one.
            let lift = min(use(of: repo), 3) * 6 + (repo.isPinned ? 10 : 0)
            return (repo, Double(match) + lift)
        }
        return scored
            .sorted { a, b in a.score != b.score ? a.score > b.score : RepoIndex.listOrder(a.repo, b.repo) }
            .map(\.repo)
    }
}
