import Foundation

/// A short plain-text record of what the app was asked to do and what came of it, for working
/// out why a click did nothing. It holds session ids and outcomes, never questions or prompts.
public struct ActivityLog: Sendable {
    public let url: URL
    public var maxLines = 200

    public init(directory: URL = PorchlightPaths.stateDirectory()) {
        url = directory.appendingPathComponent("activity.log")
    }

    public func record(_ message: String, now: Date = Date()) {
        let formatter = ISO8601DateFormatter()
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append("\(formatter.string(from: now)) \(message.replacingOccurrences(of: "\n", with: " "))")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url, options: .atomic)
    }
}
