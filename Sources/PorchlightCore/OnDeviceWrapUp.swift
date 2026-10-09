import Foundation

/// Which model writes a session's summary.
public enum WrapUpEngine: String, Codable, Sendable, Equatable, CaseIterable {
    /// Apple's on-device model: free and local, but it only has room for the first request and
    /// the end of the conversation.
    case onDevice
    /// A small Claude model through `claude`: reads all of it, and spends usage.
    case claude

    public var title: String {
        switch self {
        case .onDevice: "This Mac (free, reads the end)"
        case .claude: "Claude (reads everything)"
        }
    }
}

/// What was taken from a conversation to fit a small model.
public struct ConversationDigest: Sendable, Equatable {
    public let text: String
    /// How many turns are in it, the first request included.
    public let turns: Int
    /// True when turns between the first request and the end were left out.
    public let isPartial: Bool

    public init(text: String, turns: Int, isPartial: Bool) {
        self.text = text
        self.turns = turns
        self.isPartial = isPartial
    }
}

/// Reads what was said in a conversation from the file Claude Code keeps for it. The format is
/// not documented and may change; anything unreadable is skipped, and nothing is ever written.
public struct ConversationReader: Sendable {
    /// Claude Code's folder of conversations, one folder per working directory.
    public var projects: URL

    public static func defaultProjects() -> URL {
        // For tests and for checking the tool against a made-up folder.
        if let override = ProcessInfo.processInfo.environment["PORCHLIGHT_CONVERSATIONS_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public init(projects: URL = ConversationReader.defaultProjects()) {
        self.projects = projects
    }

    /// The conversation's file, looked for by name in each project folder. The id must be the
    /// UUID the CLI reports, so it cannot name anything outside those folders.
    public func file(for conversationID: String) -> URL? {
        guard WrapUp.isValidConversationID(conversationID) else { return nil }
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent("\(conversationID).jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// What one part of an assistant's message says, if anything. A session that is waiting
    /// has usually asked through a tool, so its question is read; of other tool calls only the
    /// one-line description the assistant gave, never the command or its output.
    static func said(in part: [String: Any]) -> String? {
        switch part["type"] as? String {
        case "text":
            return part["text"] as? String
        case "tool_use":
            let input = part["input"] as? [String: Any] ?? [:]
            if part["name"] as? String == "AskUserQuestion", let questions = input["questions"] as? [[String: Any]] {
                let asked = questions.compactMap { question -> String? in
                    guard let text = question["question"] as? String else { return nil }
                    let options = (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                    return options.isEmpty ? text : "\(text) Options: \(options.joined(separator: " / "))"
                }
                return asked.isEmpty ? nil : "Asked the user: " + asked.joined(separator: " ")
            }
            guard let description = input["description"] as? String, !description.isEmpty else { return nil }
            return "(did: \(description.prefix(120)))"
        default:
            return nil
        }
    }

    /// One line of the file as (who, what was said), or nil for everything that is not a person
    /// or the assistant speaking: tool output, side conversations, notices.
    static func turn(_ line: Data) -> (who: String, said: String)? {
        // Lines can be megabytes of tool output; only decode the ones that can matter.
        guard line.count < 400_000, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant",
              object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return nil }
        var said = ""
        if let content = message["content"] as? String {
            said = content
        } else if let parts = message["content"] as? [[String: Any]] {
            said = parts.compactMap { type == "assistant" ? Self.said(in: $0) : ($0["type"] as? String == "text" ? $0["text"] as? String : nil) }
                .joined(separator: "\n")
        }
        said = said.trimmingCharacters(in: .whitespacesAndNewlines)
        // What the harness put in the user's place starts with a tag: reminders, command output.
        guard !said.isEmpty, !(type == "user" && said.hasPrefix("<")) else { return nil }
        return (type, said)
    }

    /// The first request and as much of the end as fits in `budget` characters.
    public func digest(for conversationID: String, budget: Int = WrapUp.onDeviceBudget) -> ConversationDigest? {
        guard let file = file(for: conversationID), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        let lines = data.split(separator: UInt8(ascii: "\n"))
        guard let firstIndex = lines.firstIndex(where: { Self.turn(Data($0)) != nil }), let first = Self.turn(Data(lines[firstIndex])) else { return nil }
        let opening = String(first.said.prefix(max(200, budget / 6)))
        var used = opening.count
        var tail: [String] = []
        var reachedStart = true
        // From the end backwards, so a long conversation is not decoded line by line.
        for index in stride(from: lines.count - 1, to: firstIndex, by: -1) {
            guard let turn = Self.turn(Data(lines[index])) else { continue }
            let piece = String(turn.said.suffix(max(200, budget / 6)))
            if used + piece.count > budget {
                reachedStart = false
                break
            }
            used += piece.count
            tail.insert("\(turn.who.uppercased()): \(piece)", at: 0)
        }
        var parts = ["\(first.who.uppercased()): \(opening)"]
        if !reachedStart { parts.append("[earlier turns left out]") }
        return ConversationDigest(text: (parts + tail).joined(separator: "\n\n"), turns: tail.count + 1, isPartial: !reachedStart)
    }
}

extension WrapUp {
    /// How many characters of conversation the on-device model is given. Its window is 8,192
    /// tokens (macOS 27.0, 2026-10-09); at about 9,000 characters it answered in five seconds and
    /// accurately, and at 28,000 it invented a fact.
    public static let onDeviceBudget = 9000

    public static let onDeviceModelName = "Apple's on-device model"

    public static let onDeviceInstructions = """
        You summarise a coding assistant's session for its owner, who is deciding whether to answer it, keep it or delete it. \
        Use only what the session says; do not guess. Plain text without Markdown, under 120 words, in three short parts: \
        "Doing:" what the session was working on; "Stopped at:" where it stands and what, if anything, it is waiting for; \
        "Worth keeping:" anything unfinished, undecided or learned that would be lost if it were deleted, or "nothing".
        """
}

/// Whether Apple's on-device model can be used on this Mac.
public enum OnDeviceStatus: Sendable, Equatable {
    case available
    /// No `fm` tool: an older macOS.
    case missing
    /// The tool is there and says no, in its own words: Apple Intelligence off, or the model
    /// still downloading.
    case notReady(String)
    /// Apple's terms for the tool have not been accepted on this Mac.
    case licenceNeeded

    public var isAvailable: Bool { self == .available }

    /// What to tell the user, or nil when there is nothing to tell.
    public var explanation: String? {
        switch self {
        case .available: nil
        case .missing: "Apple's on-device model is not on this Mac; it needs macOS 26 or later with Apple Intelligence."
        case .licenceNeeded: OnDeviceModel.licenceNeeded
        case .notReady(let words):
            (words.isEmpty ? "Apple's on-device model is not ready." : "Apple's on-device model is not ready: \(words)\(".!?".contains(words.last ?? " ") ? "" : ".")")
                + " " + OnDeviceModel.licenceHint
        }
    }
}

/// What a wrap-up will use: the user's choice, and whether this Mac can honour it.
public struct WrapUpPlan: Sendable, Equatable {
    public var chosen: WrapUpEngine
    /// The Claude model, used when the engine is Claude.
    public var model: String
    public var onDevice: OnDeviceStatus

    public init(chosen: WrapUpEngine = .claude, model: String = WrapUpSettings.defaultModel, onDevice: OnDeviceStatus = .missing) {
        self.chosen = chosen
        self.model = model
        self.onDevice = onDevice
    }

    /// The engine in force: the chosen one, or Claude where the on-device model cannot be used.
    public var engine: WrapUpEngine {
        chosen == .onDevice && onDevice.isAvailable ? .onDevice : .claude
    }
}

/// Apple's on-device model, through the `fm` tool macOS ships with. Free and local.
public struct OnDeviceModel: Sendable {
    /// What to say when the tool refuses for want of the terms.
    public static let licenceNeeded = "Apple's terms for its on-device model have not been accepted on this Mac. Run \"sudo fm license\" once in a terminal; it applies to every user of the Mac."

    /// True for the tool's refusal as the owner saw it on macOS 27.0 (2026-10-09): "YOU HAVE NOT
    /// AGREED TO THE APPLE FOUNDATION MODELS CLI LEGAL NOTICE & TERMS." Which stream and exit code
    /// it uses was not seen, so only the words are looked at.
    static func asksForLicence(_ result: CLIResult) -> Bool {
        (result.stdout + result.stderr).localizedCaseInsensitiveContains("not agreed")
    }

    /// Apple's terms for the model have to be accepted once per Mac before the tool answers.
    public static let licenceHint = "If you have not accepted Apple's terms for it yet, run \"sudo fm license\" once in a terminal."

    public var executable: URL
    public var runner: CLIRunner
    public var environment: [String: String]?

    public static func defaultExecutable() -> URL {
        if let override = ProcessInfo.processInfo.environment["PORCHLIGHT_FM"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return URL(fileURLWithPath: "/usr/bin/fm")
    }

    public init(executable: URL = OnDeviceModel.defaultExecutable(), runner: CLIRunner = CLIRunner(), environment: [String: String]? = nil) {
        self.executable = executable
        self.runner = runner
        self.environment = environment
    }

    /// Asks the tool whether the model can be used.
    public func status() async -> OnDeviceStatus {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .missing }
        guard let result = try? await runner.run(executable, ["available"], environment: environment, timeout: 10) else { return .notReady("") }
        if Self.asksForLicence(result) { return .licenceNeeded }
        if result.succeeded { return .available }
        let words = WrapUp.tidy(result.stderr)
        return .notReady(words.isEmpty ? WrapUp.tidy(result.stdout) : words)
    }

    public func isAvailable() async -> Bool {
        await status().isAvailable
    }

    static func arguments() -> [String] {
        ["respond", "--no-stream", "--instructions", WrapUp.onDeviceInstructions]
    }

    func respond(to digest: ConversationDigest) async -> Result<String, WrapUpFailure> {
        do {
            let result = try await runner.run(
                executable, Self.arguments(), environment: environment, input: "The session:\n\n" + digest.text, timeout: 120)
            if Self.asksForLicence(result) { return .failure(.onDeviceUnavailable(Self.licenceNeeded)) }
            guard result.succeeded else {
                var words = WrapUp.tidy(result.stderr)
                if words.isEmpty { words = WrapUp.tidy(result.stdout) }
                // Not seen happen; said in case the tool refuses to answer before the terms are accepted.
                if words.localizedCaseInsensitiveContains("license") || words.localizedCaseInsensitiveContains("terms") {
                    words += "\n" + Self.licenceHint
                }
                return .failure(.failed(words))
            }
            let summary = WrapUp.tidy(result.stdout)
            return summary.isEmpty ? .failure(.empty) : .success(summary)
        } catch CLIError.timedOut(let seconds) {
            return .failure(.couldNotRun("no answer after \(Int(seconds)) seconds"))
        } catch {
            return .failure(.couldNotRun(error.localizedDescription))
        }
    }

    /// The summary and what it was made from. The conversation is read from Claude Code's file;
    /// neither the session nor `claude` is involved.
    public func summarise(_ session: Session, reader: ConversationReader = ConversationReader()) async -> Result<(summary: String, digest: ConversationDigest), WrapUpFailure> {
        guard let conversationID = session.summary.sessionId, WrapUp.isValidConversationID(conversationID) else { return .failure(.noConversation) }
        if let why = await status().explanation { return .failure(.onDeviceUnavailable(why)) }
        var budget = WrapUp.onDeviceBudget
        for attempt in 0..<2 {
            guard let digest = reader.digest(for: conversationID, budget: budget) else { return .failure(.conversationGone) }
            switch await respond(to: digest) {
            case .success(let summary):
                return .success((summary, digest))
            case .failure(.failed(let words)) where attempt == 0 && words.localizedCaseInsensitiveContains("context size"):
                // Characters are a guess at tokens; code and other languages take more.
                budget /= 2
            case .failure(let failure):
                return .failure(failure)
            }
        }
        return .failure(.failed("The end of the conversation does not fit the on-device model."))
    }
}

/// Wraps a session up with whichever engine is asked for and keeps the note.
public struct WrapUpRunner: Sendable {
    /// Nil when `claude` was not found; only the Claude engine needs it.
    public var claude: URL?
    public var onDevice: OnDeviceModel
    public var reader: ConversationReader
    public var archive: NotesArchive
    public var environment: [String: String]?

    public init(
        claude: URL?, onDevice: OnDeviceModel = OnDeviceModel(), reader: ConversationReader = ConversationReader(), archive: NotesArchive = NotesArchive(),
        environment: [String: String]? = nil
    ) {
        self.claude = claude
        self.onDevice = onDevice
        self.reader = reader
        self.archive = archive
        self.environment = environment
    }

    /// The engine that will really be used: the chosen one, or Claude when the on-device model
    /// is not there.
    public func engine(preferred: WrapUpEngine) async -> WrapUpEngine {
        guard preferred == .onDevice else { return .claude }
        return await onDevice.isAvailable() ? .onDevice : .claude
    }

    public func wrapUp(
        _ session: Session, engine: WrapUpEngine, model: String, branch: String? = nil, pullRequest: String? = nil, now: Date = Date()
    ) async -> Result<SessionNote, WrapUpFailure> {
        switch engine {
        case .claude:
            guard let claude else { return .failure(.couldNotRun("claude was not found")) }
            return await SessionSummariser(claude: claude, environment: environment)
                .wrapUp(session, model: model, archive: archive, branch: branch, pullRequest: pullRequest, now: now)
        case .onDevice:
            switch await onDevice.summarise(session, reader: reader) {
            case .failure(let failure):
                return .failure(failure)
            case .success(let made):
                var note = WrapUp.note(for: session, summary: made.summary, model: WrapUp.onDeviceModelName, branch: branch, pullRequest: pullRequest, now: now)
                note.engine = .onDevice
                note.turnsRead = made.digest.turns
                note.isPartial = made.digest.isPartial
                do {
                    try archive.save(note)
                } catch {
                    return .failure(.couldNotSave(error.localizedDescription))
                }
                return .success(note)
            }
        }
    }
}
