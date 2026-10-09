import Foundation

/// How a new session gets its name. Unknown keys are ignored and each value is read on its own.
public struct NamingSettings: Codable, Sendable, Equatable {
    public static let defaultTemplate = "{slug}"

    /// Text with tokens: `{repo}`, `{branch}`, `{ticket}`, `{slug}`, `{date}`.
    public var template: String
    /// A regular expression for a ticket id, tried on the prompt and then on the branch. With a
    /// capture group, the first group is the ticket. Nil means no ticket system.
    public var ticketPattern: String?

    public init(template: String = NamingSettings.defaultTemplate, ticketPattern: String? = nil) {
        self.template = template
        self.ticketPattern = ticketPattern
    }

    private enum CodingKeys: String, CodingKey {
        case template, ticketPattern
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let template = (try? c.decodeIfPresent(String.self, forKey: .template)) ?? Self.defaultTemplate
        self.template = template.trimmingCharacters(in: .whitespaces).isEmpty ? Self.defaultTemplate : template
        let pattern = try? c.decodeIfPresent(String.self, forKey: .ticketPattern)
        ticketPattern = pattern?.isEmpty == false ? pattern : nil
    }
}

/// Builds a session name from a template.
public struct NameTemplate: Sendable, Equatable {
    public static let tokens = ["repo", "branch", "ticket", "slug", "date"]
    /// Long enough to tell sessions apart, short enough for a row and a tab title.
    public static let maxLength = 60

    public var settings: NamingSettings

    public init(settings: NamingSettings = NamingSettings()) {
        self.settings = settings
    }

    /// The name for a prompt started in `directory`. Empty when there is nothing to build one
    /// from; Claude Code then names the session itself.
    public func name(prompt: String, directory: String, branch: String?, now: Date = Date(), calendar: Calendar = .current) -> String {
        let slug = Slug.make(from: prompt)
        let values: [String: String] = [
            "repo": RepoLocation(cwd: directory).repoName,
            "branch": branch ?? "",
            "ticket": ticket(prompt: prompt, branch: branch),
            "slug": slug,
            "date": Self.day(now, calendar: calendar),
        ]
        let name = Self.fill(settings.template, with: values)
        // A template made only of tokens that came out empty would leave the session unnamed.
        return name.isEmpty ? slug : name
    }

    /// The first ticket id in the prompt, else in the branch; empty when there is none.
    public func ticket(prompt: String, branch: String?) -> String {
        guard let pattern = settings.ticketPattern, let regex = try? NSRegularExpression(pattern: pattern) else { return "" }
        for text in [prompt, branch ?? ""] {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range
            if let range = Range(group, in: text), !range.isEmpty { return String(text[range]) }
        }
        return ""
    }

    /// Replaces the tokens. A token that comes out empty takes the separator after it along (or,
    /// at the end, the one before it), so `{ticket}-{slug}` without a ticket is just the slug.
    /// Unknown tokens stay as written, so a typo shows in the preview.
    static func fill(_ template: String, with values: [String: String]) -> String {
        let separators = CharacterSet(charactersIn: "-_/:. ")
        func isSeparator(_ character: Character) -> Bool { character.unicodeScalars.allSatisfy(separators.contains) }

        var result = ""
        var rest = Substring(template)
        var dropLeadingSeparators = false
        while !rest.isEmpty {
            if let token = tokens.first(where: { rest.hasPrefix("{\($0)}") }) {
                rest = rest.dropFirst(token.count + 2)
                let value = values[token] ?? ""
                if value.isEmpty {
                    dropLeadingSeparators = true
                } else {
                    result += value
                    dropLeadingSeparators = false
                }
                continue
            }
            let character = rest.removeFirst()
            if dropLeadingSeparators, isSeparator(character) { continue }
            dropLeadingSeparators = false
            result.append(character)
        }
        // An empty token at the end leaves the separator that led up to it.
        if dropLeadingSeparators {
            while let last = result.last, isSeparator(last) { result.removeLast() }
        }
        return clipped(result.trimmingCharacters(in: .whitespaces))
    }

    /// Cuts a long name at a word boundary where there is one.
    static func clipped(_ name: String) -> String {
        guard name.count > maxLength else { return name }
        let head = String(name.prefix(maxLength))
        if let cut = head.lastIndex(where: { "-_ /".contains($0) }), head.distance(from: head.startIndex, to: cut) > maxLength / 2 {
            return String(head[..<cut])
        }
        return head
    }

    static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// A few words of a prompt as a short name: "Fix the flaky settings test in CI" → "fix-flaky-settings-test".
public enum Slug {
    public static let maxWords = 4

    /// Words that say nothing about the task.
    static let filler: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "for", "from", "with", "by", "and", "or", "but", "so",
        "is", "are", "was", "be", "it", "its", "this", "that", "these", "those", "there", "as", "into",
        "i", "we", "you", "me", "my", "our", "your", "us",
        "please", "can", "could", "would", "should", "will", "want", "need", "like", "lets", "let", "just", "also", "some", "any",
    ]

    public static func make(from prompt: String) -> String {
        // The first line carries the task; later lines are usually detail or pasted text.
        let firstLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let words = firstLine
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let significant = words.filter { !filler.contains($0) }
        // A prompt made only of filler ("can you do this") still deserves a name.
        let chosen = (significant.isEmpty ? words : significant).prefix(maxWords)
        return NameTemplate.clipped(chosen.joined(separator: "-"))
    }
}

/// Reads the checked-out branch from a repository's files, without running git.
public enum GitBranch {
    /// The branch of the checkout at `directory`, or nil when it is not a repository or no branch
    /// is checked out (a detached HEAD).
    public static func current(in directory: String) -> String? {
        guard let gitDirectory = gitDirectory(of: directory),
              let head = try? String(contentsOfFile: gitDirectory + "/HEAD", encoding: .utf8)
        else { return nil }
        let line = head.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let prefix = "ref: refs/heads/"
        guard line.hasPrefix(prefix) else { return nil }
        let branch = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return branch.isEmpty ? nil : branch
    }

    /// Where the checkout keeps its HEAD: `.git` itself, or for a linked worktree or submodule
    /// the folder its `.git` file points at.
    static func gitDirectory(of directory: String) -> String? {
        let dotGit = directory + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return dotGit }
        guard let pointer = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = pointer.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return target.hasPrefix("/") ? target : URL(fileURLWithPath: directory).appendingPathComponent(target).standardizedFileURL.path
    }
}
