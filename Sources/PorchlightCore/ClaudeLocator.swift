import Foundation

/// Finds the `claude` executable. GUI apps do not inherit the shell PATH, so well-known install
/// locations are probed as well.
public struct ClaudeLocator: Sendable {
    public var override: String?
    public var environment: [String: String]
    public var homeDirectory: String
    public var isExecutable: @Sendable (String) -> Bool

    public init(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: String = NSHomeDirectory(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.override = override
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.isExecutable = isExecutable
    }

    /// Candidate paths in priority order: user setting, PATH, then common install locations.
    public func candidates() -> [String] {
        var paths: [String] = []
        if let override, !override.isEmpty { paths.append(override) }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            paths.append("\(dir)/claude")
        }
        paths.append("\(homeDirectory)/.local/bin/claude")
        paths.append("\(homeDirectory)/.claude/local/claude")
        paths.append("/opt/homebrew/bin/claude")
        paths.append("/usr/local/bin/claude")
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public func locate() -> URL? {
        candidates().first(where: isExecutable).map { URL(fileURLWithPath: $0) }
    }
}

/// A dotted numeric version such as `2.1.294`, as printed by `claude --version`.
public struct CLIVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    public init(_ components: [Int]) { self.components = components }

    /// Parses the first dotted number in the text, e.g. "2.1.294 (Claude Code)".
    public init?(parsing text: String) {
        guard let match = text.firstMatch(of: /\d+(?:\.\d+)+/) else { return nil }
        self.components = match.output.split(separator: ".").compactMap { Int($0) }
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: CLIVersion, rhs: CLIVersion) -> Bool {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: CLIVersion, rhs: CLIVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}
