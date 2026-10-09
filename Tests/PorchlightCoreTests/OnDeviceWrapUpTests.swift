import Foundation
import Testing

@testable import PorchlightCore

private let conversation = "22222222-0000-4000-8000-000000000000"

/// A made-up folder of Claude Code conversations, and a stand-in `fm`.
struct ConversationWorld {
    let scratch: URL
    let projects: URL
    let log: URL
    let input: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-conversations-\(UUID().uuidString)")
        projects = scratch.appendingPathComponent("projects")
        log = scratch.appendingPathComponent("fm.log")
        input = scratch.appendingPathComponent("fm.input")
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("-Users-u-code-app"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("-Users-u-code-other"), withIntermediateDirectories: true)
    }

    static func line(_ type: String, _ content: Any, extra: [String: Any] = [:]) -> String {
        var object: [String: Any] = ["type": type, "message": ["role": type, "content": content]]
        extra.forEach { object[$0] = $1 }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    func write(_ lines: [String], id: String = conversation, folder: String = "-Users-u-code-app") throws {
        try Data(lines.joined(separator: "\n").utf8).write(to: projects.appendingPathComponent(folder).appendingPathComponent("\(id).jsonl"))
    }

    var reader: ConversationReader { ConversationReader(projects: projects) }

    func model(_ mode: String = "normal") -> OnDeviceModel {
        OnDeviceModel(
            executable: Fixtures.directory.appendingPathComponent("fake-fm"),
            environment: ["PATH": "/usr/bin:/bin", "FAKE_FM_LOG": log.path, "FAKE_FM_INPUT": input.path, "FAKE_FM_MODE": mode])
    }

    func recorded() throws -> [String] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    func session(conversation id: String? = conversation) -> Session {
        Session(summary: SessionSummary(id: "22222222", sessionId: id, name: "rename the file", cwd: "/Users/u/code/app", kind: "background", state: .blocked))
    }
}

@Suite struct ConversationReaderTests {
    @Test func theFileIsFoundByItsIdInsideTheProjectsFolderOnly() throws {
        let world = try ConversationWorld()
        try world.write([ConversationWorld.line("user", "hello")], folder: "-Users-u-code-other")
        #expect(world.reader.file(for: conversation)?.path.hasSuffix("-Users-u-code-other/\(conversation).jsonl") == true)
        #expect(world.reader.file(for: "33333333-0000-4000-8000-000000000000") == nil)
        // Only a UUID is looked for: nothing that could walk out of the folder.
        try Data("x".utf8).write(to: world.scratch.appendingPathComponent("secret.jsonl"))
        for bad in ["../secret", "..%2Fsecret", "", "secret", "-Users-u-code-other/\(conversation)"] {
            #expect(world.reader.file(for: bad) == nil && world.reader.digest(for: bad) == nil)
        }
        #expect(ConversationReader(projects: world.scratch.appendingPathComponent("nowhere")).file(for: conversation) == nil)
    }

    @Test func aShortConversationIsTakenWhole() throws {
        let world = try ConversationWorld()
        try world.write([
            ConversationWorld.line("user", "Rename config.yml to settings.yml"),
            ConversationWorld.line("assistant", [["type": "text", "text": "Renamed. Delete the old file?"]]),
        ])
        let digest = try #require(world.reader.digest(for: conversation))
        #expect(digest.text == "USER: Rename config.yml to settings.yml\n\nASSISTANT: Renamed. Delete the old file?")
        #expect(digest.turns == 2 && !digest.isPartial)
    }

    @Test func onlyWhatWasSaidIsRead() throws {
        let world = try ConversationWorld()
        try world.write([
            #"{"type":"summary","summary":"old title"}"#,
            ConversationWorld.line("user", "<system-reminder>injected</system-reminder>"),
            ConversationWorld.line("user", "The real request"),
            ConversationWorld.line("assistant", [["type": "tool_use", "name": "Bash", "input": ["command": "SECRET_COMMAND"]]]),
            ConversationWorld.line("user", [["type": "tool_result", "content": "SECRET_OUTPUT"]]),
            ConversationWorld.line("assistant", [["type": "thinking", "thinking": "SECRET_THOUGHT"], ["type": "text", "text": "Done with step one."]]),
            ConversationWorld.line("assistant", "a side conversation", extra: ["isSidechain": true]),
            ConversationWorld.line("user", "a note from the harness", extra: ["isMeta": true]),
            "{not json",
            "",
            ConversationWorld.line("user", "<local-command-stdout>noise</local-command-stdout>"),
            ConversationWorld.line("user", "Go on"),
        ])
        let digest = try #require(world.reader.digest(for: conversation))
        #expect(digest.text == "USER: The real request\n\nASSISTANT: Done with step one.\n\nUSER: Go on")
        #expect(digest.turns == 3 && !digest.isPartial)
        // Nothing at all that was said: no digest.
        try world.write([ConversationWorld.line("user", [["type": "tool_result", "content": "x"]])])
        #expect(world.reader.digest(for: conversation) == nil)
    }

    /// The shape the real file had for a session that was waiting (lantern-probe, 2026-10-09):
    /// the assistant wrote no text at all; its question was a tool call.
    @Test func aQuestionAskedThroughAToolIsReadAndSoIsWhatAToolCallWasFor() throws {
        let world = try ConversationWorld()
        let question: [String: Any] = [
            "question": "Should hello.txt be renamed to greeting.txt or salute.txt?", "header": "Rename",
            "options": [["label": "greeting.txt (Recommended)", "description": "plainer"], ["label": "salute.txt", "description": "formal"]],
        ]
        try world.write([
            ConversationWorld.line("user", "Create hello.txt and ask about its name"),
            ConversationWorld.line("assistant", [["type": "tool_use", "name": "Bash", "input": ["command": "SECRET_COMMAND", "description": "Create hello.txt and commit it"]]]),
            ConversationWorld.line("user", [["type": "tool_result", "content": "SECRET_OUTPUT"]]),
            ConversationWorld.line("assistant", [["type": "tool_use", "name": "AskUserQuestion", "input": ["questions": [question]]]]),
        ])
        let digest = try #require(world.reader.digest(for: conversation))
        #expect(digest.text == """
            USER: Create hello.txt and ask about its name

            ASSISTANT: (did: Create hello.txt and commit it)

            ASSISTANT: Asked the user: Should hello.txt be renamed to greeting.txt or salute.txt? Options: greeting.txt (Recommended) / salute.txt
            """)
        #expect(!digest.text.contains("SECRET"))
    }

    @Test func aLongConversationKeepsItsFirstRequestAndItsEnd() throws {
        let world = try ConversationWorld()
        var lines = [ConversationWorld.line("user", "FIRST " + String(repeating: "a", count: 3000))]
        for index in 1...60 {
            lines.append(ConversationWorld.line(index.isMultiple(of: 2) ? "user" : "assistant", "turn \(index) " + String(repeating: "b", count: 300)))
        }
        try world.write(lines)
        let digest = try #require(world.reader.digest(for: conversation, budget: 3000))
        #expect(digest.isPartial)
        #expect(digest.text.count <= 3000 + 200 && digest.text.count > 2000)
        // The first request is there, cut to its share; then the gap is said; then the very end.
        #expect(digest.text.hasPrefix("USER: FIRST aaaa") && digest.text.contains("\n\n[earlier turns left out]\n\n"))
        #expect(digest.text.contains("USER: turn 60 ") && digest.text.contains("ASSISTANT: turn 59 ") && !digest.text.contains("turn 1 "))
        #expect(digest.turns == digest.text.components(separatedBy: "\n\n").count - 1)
        // One enormous last turn is cut to its end, not dropped.
        try world.write([ConversationWorld.line("user", "start"), ConversationWorld.line("assistant", String(repeating: "c", count: 5000) + " THE END")])
        let cut = try #require(world.reader.digest(for: conversation, budget: 3000))
        #expect(cut.text.hasSuffix(" THE END") && cut.text.count < 800 && !cut.isPartial)
    }
}

@Suite struct OnDeviceWrapUpTests {
    func world() throws -> ConversationWorld {
        let world = try ConversationWorld()
        try world.write([
            ConversationWorld.line("user", "Rename config.yml to settings.yml"),
            ConversationWorld.line("assistant", [["type": "text", "text": "Renamed. Delete the old file?"]]),
        ])
        return world
    }

    @Test func theModelIsAskedThroughFmWithTheDigestOnStandardInput() async throws {
        let world = try world()
        let made = try await world.model().summarise(world.session(), reader: world.reader).get()
        #expect(made.summary.hasPrefix("Doing: renaming the config file.") && made.summary.contains("\nStopped at: waiting for a yes."))
        #expect(made.digest.turns == 2 && !made.digest.isPartial)
        #expect(try world.recorded() == ["available", "respond", "--no-stream", "--instructions", WrapUp.onDeviceInstructions])
        let given = try String(contentsOf: world.input, encoding: .utf8)
        #expect(given == "The session:\n\nUSER: Rename config.yml to settings.yml\n\nASSISTANT: Renamed. Delete the old file?")
        // The conversation never rides on the command line, where other processes could read it.
        #expect(try !world.recorded().contains { $0.contains("config.yml") })
        #expect(WrapUp.onDeviceInstructions.contains("do not guess"))
    }

    @Test func itCountsAsUnavailableWhenTheToolIsMissingOrSaysSo() async throws {
        let world = try world()
        #expect(await world.model().status() == .available)
        #expect(await world.model().isAvailable())
        let off = await world.model("unavailable").status()
        #expect(off == .notReady("System model unavailable: Apple Intelligence is not enabled"))
        #expect(off.explanation == "Apple's on-device model is not ready: System model unavailable: Apple Intelligence is not enabled. "
            + "If you have not accepted Apple's terms for it yet, run \"sudo fm license\" once in a terminal.")
        #expect(OnDeviceStatus.notReady("").explanation?.hasPrefix("Apple's on-device model is not ready. If you") == true)
        let missing = OnDeviceModel(executable: URL(fileURLWithPath: "/nonexistent/fm"))
        #expect(await missing.status() == .missing)
        #expect(OnDeviceStatus.missing.explanation?.contains("macOS 26") == true && OnDeviceStatus.available.explanation == nil)

        // Unavailable: nothing is read and nothing is asked.
        let refused = await world.model("unavailable").summarise(world.session(), reader: world.reader)
        guard case .failure(.onDeviceUnavailable(let why)) = refused.map(\.summary) else {
            Issue.record("expected unavailable, got \(refused.map(\.summary))")
            return
        }
        #expect(why.contains("Apple Intelligence is not enabled") && why.contains("sudo fm license"))
        #expect(try !world.recorded().contains("respond"))
        // The engine in force falls back to Claude, and Claude is never swapped for anything.
        let fallback = WrapUpRunner(claude: nil, onDevice: world.model("unavailable"), reader: world.reader)
        #expect(await fallback.engine(preferred: .onDevice) == .claude)
        #expect(await WrapUpRunner(claude: nil, onDevice: world.model(), reader: world.reader).engine(preferred: .onDevice) == .onDevice)
        #expect(await WrapUpRunner(claude: nil, onDevice: world.model(), reader: world.reader).engine(preferred: .claude) == .claude)
    }

    @Test func aContextOverflowIsTriedOnceMoreWithHalfTheText() async throws {
        let world = try ConversationWorld()
        var lines = [ConversationWorld.line("user", "FIRST request")]
        for index in 1...80 { lines.append(ConversationWorld.line("assistant", "turn \(index) " + String(repeating: "b", count: 400))) }
        try world.write(lines)
        let made = try await world.model("overflow-once").summarise(world.session(), reader: world.reader).get()
        #expect(try world.recorded().filter { $0 == "respond" }.count == 2)
        let given = try String(contentsOf: world.input, encoding: .utf8)
        #expect(given.count < WrapUp.onDeviceBudget / 2 + 300 && given.contains("turn 80 "))
        #expect(made.digest.isPartial && made.summary.contains("Stopped at:"))
    }

    @Test func failuresComeBackInTheToolsWords() async throws {
        let world = try world()
        #expect(await world.model("fail").summarise(world.session(), reader: world.reader).map(\.summary) == .failure(.failed("Error: The model refused the request.")))
        #expect(await world.model("empty").summarise(world.session(), reader: world.reader).map(\.summary) == .failure(.empty))
        let licence = await world.model("licence").summarise(world.session(), reader: world.reader).map(\.summary)
        #expect(licence == .failure(.failed("Error: You must agree to the license before using this tool.\n" + OnDeviceModel.licenceHint)))
        // No file for it any more, or no conversation id at all.
        let gone = Session(summary: SessionSummary(id: "a", sessionId: "33333333-0000-4000-8000-000000000000", name: "n", state: .done))
        #expect(await world.model().summarise(gone, reader: world.reader).map(\.summary) == .failure(.conversationGone))
        #expect(await world.model().summarise(world.session(conversation: nil), reader: world.reader).map(\.summary) == .failure(.noConversation))
        #expect(WrapUpFailure.conversationGone.message == "Claude Code no longer has this session's conversation on disk.")
    }

    @Test func theNoteSaysItWasMadeOnThisMacAndClaudeIsNeverRun() async throws {
        let world = try world()
        let fake = try FakeClaude()
        let archive = NotesArchive(directory: world.scratch.appendingPathComponent("notes"))
        let now = Date(timeIntervalSince1970: 1_791_540_000)
        let runner = WrapUpRunner(claude: Fixtures.fakeClaude, onDevice: world.model(), reader: world.reader, archive: archive, environment: fake.environment())
        let note = try await runner.wrapUp(world.session(), engine: .onDevice, model: "haiku", branch: "rename", now: now).get()
        #expect(note.engine == .onDevice && note.madeOnDevice && note.model == "Apple's on-device model" && note.turnsRead == 2 && note.isPartial == false)
        #expect(note.branch == "rename" && note.sessionID == conversation && archive.note(for: "22222222") == note)
        #expect(!FileManager.default.fileExists(atPath: fake.log.path))

        // The other engine goes through claude and says so in its note; without claude it cannot.
        let viaClaude = try await runner.wrapUp(world.session(), engine: .claude, model: "haiku", now: now).get()
        #expect(viaClaude.engine == .claude && viaClaude.model == "haiku" && viaClaude.turnsRead == nil)
        #expect(try fake.recorded().contains("--print") && world.recorded().filter { $0 == "respond" }.count == 1)
        let without = WrapUpRunner(claude: nil, onDevice: world.model(), reader: world.reader, archive: archive)
        #expect(await without.wrapUp(world.session(), engine: .claude, model: "haiku") == .failure(.couldNotRun("claude was not found")))

        // A failure leaves the note that was there.
        let failing = WrapUpRunner(claude: nil, onDevice: world.model("fail"), reader: world.reader, archive: archive)
        #expect((try? await failing.wrapUp(world.session(), engine: .onDevice, model: "haiku").get()) == nil)
        #expect(archive.note(for: "22222222") == viaClaude)
    }

    @Test func theEngineSettingDefaultsToThisMacAndOldNotesStillLoad() throws {
        #expect(WrapUpSettings().engine == .onDevice)
        let decode = { (json: String) in try JSONDecoder().decode(WrapUpSettings.self, from: Data(json.utf8)) }
        #expect(try decode("{}").engine == .onDevice)
        #expect(try decode(#"{"engine":"claude","model":"sonnet"}"#) == WrapUpSettings(model: "sonnet", engine: .claude))
        #expect(try decode(#"{"engine":"gpt"}"#).engine == .onDevice)
        #expect(try JSONDecoder().decode(WrapUpSettings.self, from: JSONEncoder().encode(WrapUpSettings(engine: .claude))).engine == .claude)
        // A note from before there was a choice has no engine: it was Claude's.
        let old = #"{"id":"a","sessionID":"\#(conversation)","name":"n","repo":"r","directory":"/d","summary":"s","model":"haiku","createdAt":"2026-10-09T11:29:35Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let note = try decoder.decode(SessionNote.self, from: Data(old.utf8))
        #expect(note.engine == nil && !note.madeOnDevice && note.turnsRead == nil)
        #expect(WrapUpEngine.allCases.map(\.title) == ["This Mac (free, reads the end)", "Claude (reads everything)"])
    }
}
