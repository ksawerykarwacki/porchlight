import Foundation

/// How a session is summarised before it is cleared away.
public struct WrapUpSettings: Codable, Sendable, Equatable {
    public static let defaultModel = "haiku"

    /// The model alias or name given to `claude --model`. A small one: the summary is read by a
    /// person deciding in a few seconds, and the whole conversation is the input.
    public var model: String

    public init(model: String = WrapUpSettings.defaultModel) {
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case model
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? Self.defaultModel
        self.model = WrapUp.isValidModel(model) ? model : Self.defaultModel
    }
}

/// A session's summary, kept after the session itself is gone.
public struct SessionNote: Codable, Sendable, Equatable, Identifiable {
    /// The short id the session had.
    public let id: String
    /// The conversation's own id: `claude --resume <sessionID>` opens it again, also after the
    /// session has been removed from the list, since the transcript stays on disk.
    public let sessionID: String
    public let name: String
    public let repo: String
    public let directory: String
    public var branch: String?
    public var pullRequest: String?
    public let summary: String
    public let model: String
    public let createdAt: Date

    public init(
        id: String, sessionID: String, name: String, repo: String, directory: String, branch: String? = nil, pullRequest: String? = nil,
        summary: String, model: String, createdAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.repo = repo
        self.directory = directory
        self.branch = branch
        self.pullRequest = pullRequest
        self.summary = summary
        self.model = model
        self.createdAt = createdAt
    }

    /// What to type to open the conversation again.
    public var resumeCommand: String {
        "cd \(ShellQuote.quote(directory)) && claude --resume \(sessionID)"
    }
}

/// The notes on disk: one file per session, in Porchlight's own folder.
public struct NotesArchive: Sendable {
    public var directory: URL

    public init(directory: URL = PorchlightPaths.stateDirectory().appendingPathComponent("notes", isDirectory: true)) {
        self.directory = directory
    }

    func url(for id: String) -> URL? {
        // The id becomes a file name: nothing that could leave the folder.
        guard SessionControl.isValidID(id) else { return nil }
        return directory.appendingPathComponent("\(id).json")
    }

    public func save(_ note: SessionNote) throws {
        guard let url = url(for: note.id) else { throw CocoaError(.fileWriteInvalidFileName) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(note).write(to: url, options: .atomic)
    }

    public func note(for id: String) -> SessionNote? {
        guard let url = url(for: id), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionNote.self, from: data)
    }

    /// Every readable note, newest first. A file that cannot be read is skipped.
    public func all() -> [SessionNote] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { note(for: $0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id }
    }

    /// The notes whose name, repository, branch or summary contain every word of the text.
    public func search(_ text: String) -> [SessionNote] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return all() }
        return all().filter { note in
            let haystack = [note.name, note.repo, note.branch ?? "", note.summary].joined(separator: "\n").lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }
}

public enum WrapUpFailure: Error, Sendable, Equatable {
    /// The session has no conversation id to resume.
    case noConversation
    /// The installed CLI lacks one of the flags a safe summary needs.
    case notSupported(missing: [String])
    case invalidModel(String)
    /// `claude` failed. The text is its own.
    case failed(String)
    case couldNotRun(String)
    case empty
    /// The summary was made but the note could not be written.
    case couldNotSave(String)

    public var message: String {
        switch self {
        case .noConversation: "This session has no conversation to summarise."
        case .notSupported(let missing): "This version of Claude Code cannot do this safely: it has no \(missing.joined(separator: ", "))."
        case .invalidModel(let model): "\"\(model)\" is not a model name."
        case .failed(let text): text.isEmpty ? "Claude Code could not summarise the session." : text
        case .couldNotRun(let text): "Could not run claude: \(text)"
        case .empty: "Claude Code returned no summary."
        case .couldNotSave(let text): "The summary could not be saved: \(text)"
        }
    }
}

/// Summarising a session through the unmodified `claude` CLI.
///
/// The conversation is resumed as a *fork* in print mode, so the session itself gets no new turn;
/// nothing is saved, so no new session appears; and every tool is off, so the summariser can only
/// read the conversation and answer. It runs only when the user asks for it: it spends usage.
public enum WrapUp {
    /// The flags the command needs, all of which must be listed by `claude --help`.
    public static let requiredFlags = ["--print", "--resume", "--fork-session", "--no-session-persistence", "--tools", "--model"]

    public static let prompt = """
        Summarise this session for its owner, who is deciding whether to answer it, keep it or delete it. \
        Do not use any tools and do not continue the work. Plain text, under 120 words, in three short parts: \
        "Doing:" what the session was working on; "Stopped at:" where it stands and what, if anything, it is waiting for; \
        "Worth keeping:" anything unfinished, undecided or learned that would be lost if it were deleted, or "nothing" if there is none.
        """

    /// The flags from `requiredFlags` that the help text does not list.
    public static func missingFlags(help: String) -> [String] {
        let text = ANSI.strip(help).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return requiredFlags.filter { flag in
            text.range(of: "(^|[ ,])\(NSRegularExpression.escapedPattern(for: flag))([ ,]|$)", options: .regularExpression) == nil
        }
    }

    /// A conversation id as the CLI reports it: a UUID.
    public static func isValidConversationID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// A model alias or full name: letters, digits and a few separators, never a flag.
    public static func isValidModel(_ model: String) -> Bool {
        !model.isEmpty && model.count <= 80 && model.first != "-"
            && model.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._:[]".contains($0)) }
    }

    /// Where to resume from, best first. Claude Code finds a conversation by the folder it ran
    /// in, and a stopped session reports the repository as its folder, so the worktree its job
    /// names comes first.
    public static func folders(for session: Session) -> [String] {
        var folders: [String] = []
        for folder in [session.job?.worktreePath ?? "", session.summary.cwd, session.location.repoRoot] where !folder.isEmpty && !folders.contains(folder) {
            folders.append(folder)
        }
        return folders
    }

    public static func arguments(conversationID: String, model: String) throws -> [String] {
        guard isValidConversationID(conversationID) else { throw WrapUpFailure.noConversation }
        guard isValidModel(model) else { throw WrapUpFailure.invalidModel(model) }
        // `--tools` takes a list: the empty string means none, and the option after it ends the list.
        return [
            "--print", "--resume", conversationID, "--fork-session", "--no-session-persistence", "--tools", "", "--model", model,
            "--", prompt,
        ]
    }
}

public struct SessionSummariser: Sendable {
    public var claude: URL
    public var runner: CLIRunner
    public var environment: [String: String]?

    public init(claude: URL, runner: CLIRunner = CLIRunner(), environment: [String: String]? = nil) {
        self.claude = claude
        self.runner = runner
        self.environment = environment
    }

    /// The summary text. Checks first that this CLI lists every flag the command uses; if one
    /// is missing, nothing is run, because without it the session could be changed.
    public func summarise(_ session: Session, model: String) async -> Result<String, WrapUpFailure> {
        guard let conversationID = session.summary.sessionId else { return .failure(.noConversation) }
        let arguments: [String]
        do {
            arguments = try WrapUp.arguments(conversationID: conversationID, model: model)
        } catch let failure as WrapUpFailure {
            return .failure(failure)
        } catch {
            return .failure(.couldNotRun("\(error)"))
        }
        guard let help = try? await runner.run(claude, ["--help"], environment: environment, timeout: 10), help.succeeded else {
            return .failure(.couldNotRun("its help could not be read"))
        }
        let missing = WrapUp.missingFlags(help: help.stdout)
        guard missing.isEmpty else { return .failure(.notSupported(missing: missing)) }

        let folder = WrapUp.folders(for: session).first(where: RepoIndex.directoryExists)
        do {
            let result = try await runner.run(
                claude, arguments, cwd: folder.map { URL(fileURLWithPath: $0, isDirectory: true) }, environment: environment, timeout: 240)
            guard result.succeeded else {
                let words = ANSI.strip(result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.failed(words.isEmpty ? ANSI.strip(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines) : words))
            }
            let summary = ANSI.strip(result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            return summary.isEmpty ? .failure(.empty) : .success(summary)
        } catch CLIError.timedOut(let seconds) {
            return .failure(.couldNotRun("no answer after \(Int(seconds)) seconds"))
        } catch {
            return .failure(.couldNotRun(error.localizedDescription))
        }
    }

    /// Summarises the session and keeps the result as a note, replacing an older note for it.
    public func wrapUp(
        _ session: Session, model: String, archive: NotesArchive, branch: String? = nil, pullRequest: String? = nil, now: Date = Date()
    ) async -> Result<SessionNote, WrapUpFailure> {
        switch await summarise(session, model: model) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let summary):
            let folders = WrapUp.folders(for: session)
            let note = SessionNote(
                id: session.id, sessionID: session.summary.sessionId ?? "", name: session.name, repo: session.location.repoName,
                directory: folders.first(where: RepoIndex.directoryExists) ?? folders.first ?? "", branch: branch, pullRequest: pullRequest,
                summary: summary, model: model, createdAt: now)
            do {
                try archive.save(note)
            } catch {
                return .failure(.couldNotSave(error.localizedDescription))
            }
            return .success(note)
        }
    }
}
