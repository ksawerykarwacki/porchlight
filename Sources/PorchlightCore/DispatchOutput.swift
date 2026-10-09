import Foundation

/// Parsing of what `claude --bg` prints.
public enum DispatchOutput {
    /// The short session id from "backgrounded · <id> · <name>". The CLI colours the id even when
    /// stdout is not a terminal.
    public static func sessionID(from stdout: String) -> String? {
        let text = ANSI.strip(stdout)
        if let match = text.firstMatch(of: /backgrounded\s*·\s*([0-9a-f]{8})\b/) {
            return String(match.output.1)
        }
        return text.firstMatch(of: /\b([0-9a-f]{8})\b/).map { String($0.output.1) }
    }

    /// The name from "backgrounded · <id> · <name>", when the line has one.
    public static func sessionName(from stdout: String) -> String? {
        let text = ANSI.strip(stdout)
        guard let match = text.firstMatch(of: /backgrounded\s*·\s*[0-9a-f]{8}\s*·[ \t]*([^\n]+)/) else { return nil }
        let name = match.output.1.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

public enum DispatchFailure: Sendable, Equatable {
    /// Claude Code refuses to start in a folder whose trust prompt was never accepted. Only the
    /// user can accept it, by running `claude` there once.
    case workspaceNotTrusted(path: String?)
    case other(String)

    public init(stderr: String) {
        let text = ANSI.strip(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("Workspace not trusted") {
            let path = text.firstMatch(of: /Run `claude` in (.+?) once/).map { String($0.output.1) }
            self = .workspaceNotTrusted(path: path)
        } else {
            self = .other(text)
        }
    }
}
