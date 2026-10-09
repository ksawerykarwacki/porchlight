import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

/// What the palette asked its services for, and what they should answer.
final class PaletteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [DispatchRequest] = []
    private var storedHistory = DispatchHistory()
    private var storedRepos = RepoIndexSettings()
    private var storedFailure: DispatchError?
    private var storedRows: [InboxRow] = []

    var rows: [InboxRow] {
        get { lock.withLock { storedRows } }
        set { lock.withLock { storedRows = newValue } }
    }

    var requests: [DispatchRequest] { lock.withLock { storedRequests } }
    var history: DispatchHistory {
        get { lock.withLock { storedHistory } }
        set { lock.withLock { storedHistory = newValue } }
    }
    var repos: RepoIndexSettings {
        get { lock.withLock { storedRepos } }
        set { lock.withLock { storedRepos = newValue } }
    }
    var failure: DispatchError? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }

    func record(_ request: DispatchRequest) { lock.withLock { storedRequests.append(request) } }
}

@MainActor
struct PaletteHarness {
    nonisolated static let now = Date(timeIntervalSince1970: 1_791_540_000)
    nonisolated static let home = "/Users/u"
    nonisolated static let names = ["porchlight", "payments-api", "api-gateway", "docs", "infra", "website", "mobile", "billing", "search", "notes"]

    let probe = PaletteProbe()
    let model: PaletteModel
    var started: [(Dispatched, Bool)] { startedBox.values }
    let startedBox = Box<(Dispatched, Bool)>()
    let opened = Box<Dispatched>()
    let trusted = Box<String>()
    let copied = Box<String>()
    let closed = Box<Void>()

    final class Box<Value>: @unchecked Sendable {
        var values: [Value] = []
    }

    init(names: [String] = PaletteHarness.names, capabilities: DispatchCapabilities? = nil, naming: NamingSettings = NamingSettings()) throws {
        let probe = probe
        let help = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("PorchlightCoreTests/Fixtures/claude-help.txt"), encoding: .utf8)
        let known = capabilities ?? DispatchCapabilities(help: help)
        let folders = Set(names.map { "/Users/u/code/\($0)" } + ["/Users/u/elsewhere/loose"])
        let services = PaletteServices(
            loadIndex: {
                RepoIndex(
                    scanned: names.map { "/Users/u/code/\($0)" }, sessionDirectories: ["/Users/u/code/docs"], settings: probe.repos,
                    home: PaletteHarness.home, exists: { _ in true })
            },
            sessions: { probe.rows },
            loadHistory: { probe.history },
            saveHistory: { probe.history = $0 },
            naming: { naming },
            capabilities: { known },
            dispatch: { request, _ in
                probe.record(request)
                if let failure = probe.failure { throw failure }
                return Dispatched(id: "4cb41c2a", name: request.name, directory: request.directory)
            },
            branch: { $0.hasSuffix("porchlight") ? "feature/OPS-9-palette" : nil },
            isFolder: { folders.contains($0) },
            updateRepos: { change in
                var repos = probe.repos
                change(&repos)
                probe.repos = repos
            },
            now: { PaletteHarness.now },
            home: PaletteHarness.home)
        model = PaletteModel(services: services)
        let (startedBox, opened, trusted, copied, closed) = (startedBox, opened, trusted, copied, closed)
        model.onStarted = { startedBox.values.append(($0, $1)) }
        model.onOpen = { opened.values.append($0) }
        model.onTrust = { trusted.values.append($0) }
        model.onCopy = { copied.values.append($0) }
        model.onClose = { closed.values.append(()) }
    }

    /// Opens the palette, picks a repository by typing, and writes a prompt.
    func ready(typing query: String = "porch", prompt: String = "Fix the gap under the menu bar") async {
        await model.begin()
        model.setQuery(query)
        model.confirmFolder()
        model.setPrompt(prompt)
    }
}

@MainActor
@Suite struct PaletteModelTests {
    @Test func opensOnTheFolderStepWithEveryRepositoryRanked() async throws {
        let harness = try PaletteHarness()
        harness.probe.repos.setPinned("/Users/u/code/notes", true, home: PaletteHarness.home)
        harness.probe.history = DispatchHistory(entries: [.init(directory: "/Users/u/code/website", date: PaletteHarness.now)])
        #expect(harness.model.isLoading)
        await harness.model.begin()
        let model = harness.model
        #expect(model.step == .folder && !model.isLoading)
        #expect(model.results.count == 10)
        // Pinned, then used, then the one with sessions, then by name.
        #expect(model.results.prefix(4).map(\.name) == ["notes", "website", "docs", "api-gateway"])
        #expect(model.selectedRepo?.name == "notes")
        #expect(model.capabilities.effortLevels.contains("high"))
    }

    @Test func typingNarrowsTheListAndArrowsMoveWithinIt() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        await model.begin()
        model.moveSelection(by: 3)
        model.setQuery("api")
        // A new search starts at the top.
        #expect(model.selection == 0)
        #expect(model.results.map(\.name) == ["api-gateway", "payments-api"])
        model.moveSelection(by: 1)
        #expect(model.selectedRepo?.name == "payments-api")
        model.moveSelection(by: 5)
        #expect(model.selectedRepo?.name == "payments-api")
        model.moveSelection(by: -9)
        #expect(model.selectedRepo?.name == "api-gateway")
        model.setQuery("zzz")
        #expect(model.results.isEmpty && model.selectedRepo == nil)
        model.confirmFolder()
        #expect(model.step == .folder)
    }

    @Test func theListShowsAWindowThatFollowsTheSelection() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        await model.begin()
        #expect(model.visibleItems.count == PaletteModel.visibleRows)
        #expect(model.visibleItems.first == model.items.first)
        model.moveSelection(by: 9)
        #expect(model.visibleItems.last == model.items.last)
        #expect(model.visibleItems.contains(model.selectedItem!))
        model.moveSelection(by: -9)
        #expect(model.visibleItems.first == model.items.first)
    }

    @Test func aTypedPathIsOfferedAsAFolderEvenOutsideTheList() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        await model.begin()
        model.setQuery("~/elsewhere/loose")
        #expect(model.results.map(\.path) == ["/Users/u/elsewhere/loose"])
        #expect(model.results.first?.isIndexed == false)
        model.setQuery("/Users/u/code/docs/")
        // A path to a listed repository is that repository, sessions and all.
        #expect(model.results.first?.hasSessions == true)
        model.setQuery("~/nowhere")
        #expect(model.results.isEmpty)
    }

    @Test func choosingAFolderMovesToThePromptAndEscapeGoesBack() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        await model.begin()
        let focusAtStart = model.focusRequest
        model.setQuery("porch")
        model.confirmFolder()
        #expect(model.step == .prompt)
        #expect(model.folder?.path == "/Users/u/code/porchlight")
        #expect(model.branch == "feature/OPS-9-palette")
        // The keyboard is asked for again, for the prompt.
        #expect(model.focusRequest > focusAtStart)
        #expect(!model.canStart)

        model.escape()
        #expect(model.step == .folder && model.query == "porch")
        model.escape()
        #expect(harness.closed.values.count == 1)
    }

    @Test func theNameFollowsThePromptUntilItIsEdited() async throws {
        let harness = try PaletteHarness(naming: NamingSettings(template: "{ticket}-{slug}", ticketPattern: "[A-Z]+-\\d+"))
        let model = harness.model
        await harness.ready(prompt: "Fix the gap under the menu bar")
        // Ticket from the branch, slug from the prompt.
        #expect(model.name == "OPS-9-fix-gap-under-menu")
        model.setPrompt("Rename the settings tab")
        #expect(model.name == "OPS-9-rename-settings-tab")

        model.setName("my own name")
        model.setPrompt("Something else entirely")
        #expect(model.name == "my own name" && model.editedName == "my own name")
        // Emptying the field goes back to the suggestion.
        model.setName("  ")
        #expect(model.editedName == nil && model.name == "OPS-9-something-else-entirely")
    }

    @Test func startingDispatchesWithTheNameShownAndRemembersIt() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        await harness.ready()
        model.options.effort = "high"
        model.options.model = "opus"
        #expect(model.canStart)
        await model.start(open: false)

        #expect(harness.probe.requests == [
            DispatchRequest(
                directory: "/Users/u/code/porchlight", prompt: "Fix the gap under the menu bar", name: "fix-gap-under-menu",
                model: "opus", effort: "high", agent: "", permissionMode: nil, worktree: nil),
        ])
        let started = Dispatched(id: "4cb41c2a", name: "fix-gap-under-menu", directory: "/Users/u/code/porchlight")
        #expect(model.step == .started(started))
        #expect(harness.started.count == 1 && harness.started[0].0 == started && harness.started[0].1 == false)
        // Not opened, so the palette stays to show the result.
        #expect(harness.closed.values.isEmpty)
        #expect(harness.probe.history.last == .init(directory: "/Users/u/code/porchlight", name: "fix-gap-under-menu", model: "opus", date: PaletteHarness.now))

        // Return on the result closes; Open opens and closes.
        model.openStarted()
        #expect(harness.opened.values == [started] && harness.closed.values.count == 1)
    }

    @Test func anEditedNameWinsAndAWorktreeIsAskedForWhenSwitchedOn() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        await harness.ready()
        model.setName("hand picked")
        model.options.usesWorktree = true
        model.options.worktreeName = "gap-fix"
        model.options.permissionMode = "acceptEdits"
        await model.start(open: false)
        let request = try #require(harness.probe.requests.first)
        #expect(request.name == "hand picked")
        #expect(request.worktree == .named("gap-fix"))
        #expect(request.permissionMode == "acceptEdits")
    }

    @Test func dispatchAndOpenAlsoOpensAndClosesThePalette() async throws {
        let harness = try PaletteHarness()
        await harness.ready()
        await harness.model.start(open: true)
        #expect(harness.started.count == 1 && harness.started[0].1 == true)
        #expect(harness.closed.values.count == 1)
    }

    @Test func nothingStartsWithoutAPromptOrTwice() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        await harness.ready(prompt: "  \n ")
        await model.start(open: false)
        #expect(harness.probe.requests.isEmpty && model.step == .prompt)
        model.setPrompt("go")
        await model.start(open: false)
        // Already started: a second ⌘Return does nothing.
        await model.start(open: false)
        #expect(harness.probe.requests.count == 1)
    }

    @Test func aFailureShowsTheCLIsWordsAndGoesBackToThePromptIntact() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        harness.probe.failure = .failed(.other("error: unknown option '--effort'"), command: "cd /Users/u/code/porchlight && claude --bg -- x")
        await harness.ready(prompt: "keep this text")
        await model.start(open: true)
        #expect(model.step == .failed(message: "error: unknown option '--effort'", command: "cd /Users/u/code/porchlight && claude --bg -- x", untrustedFolder: nil))
        // Nothing was started, so nothing is opened, closed or remembered.
        #expect(harness.started.isEmpty && harness.closed.values.isEmpty && harness.probe.history.entries.isEmpty)
        model.copyFailedCommand()
        #expect(harness.copied.values == ["cd /Users/u/code/porchlight && claude --bg -- x"])
        model.trustFolder()
        #expect(harness.trusted.values.isEmpty)

        model.confirm()
        #expect(model.step == .prompt && model.prompt == "keep this text" && model.folder?.name == "porchlight")
    }

    @Test func anUntrustedFolderOffersToOpenClaudeCodeThere() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        harness.probe.failure = .failed(.workspaceNotTrusted(path: "/Users/u/code/porchlight"), command: "cd … && claude --bg -- x")
        await harness.ready()
        await model.start(open: false)
        guard case .failed(let message, _, let folder) = model.step else {
            Issue.record("expected a failure")
            return
        }
        #expect(folder == "/Users/u/code/porchlight")
        #expect(message.contains("accept the trust prompt"))
        model.trustFolder()
        #expect(harness.trusted.values == ["/Users/u/code/porchlight"])
    }

    @Test func sameAsLastTimePicksTheLastFolderAndModel() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        await model.begin()
        #expect(!model.canRepeatLast)
        harness.probe.history = DispatchHistory(entries: [
            .init(directory: "/Users/u/code/billing", name: "x", model: "opus", date: PaletteHarness.now),
            .init(directory: "/Users/u/code/docs", date: PaletteHarness.now - 100),
        ])
        await model.begin()
        #expect(model.canRepeatLast)
        model.repeatLast()
        #expect(model.step == .prompt && model.folder?.name == "billing")
        #expect(model.options.model == "opus" && model.showsOptions)
        // A folder that is gone cannot be repeated.
        harness.probe.history = DispatchHistory(entries: [.init(directory: "/Users/u/gone", date: PaletteHarness.now)])
        await model.begin()
        #expect(!model.canRepeatLast)
    }

    @Test func pinningAndAddingAFolderAreSavedAndReopeningStartsClean() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        await harness.ready()
        model.setName("edited")
        model.options.effort = "max"
        await model.begin()
        #expect(model.step == .folder && model.query.isEmpty && model.prompt.isEmpty && model.editedName == nil)
        #expect(model.options == PaletteModel.Options() && model.folder == nil)

        let docs = try #require(model.results.first { $0.name == "docs" })
        model.togglePin(docs)
        #expect(harness.probe.repos.pinned == ["~/code/docs"])
        model.addRoot(path: "/Users/u/elsewhere/loose")
        model.addRoot(path: "/Users/u/not-a-folder")
        #expect(harness.probe.repos.roots == ["~/elsewhere/loose"])
    }
}

@MainActor
@Suite struct PaletteViewTests {
    func render(_ model: PaletteModel, named name: String) throws -> NSBitmapImageRep {
        let view = PaletteView(model: model, hover: HoverTracker(), drawsFields: false)
        let renderer = ImageRenderer(content: view.padding(12).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        if let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }

    /// How many pixels are close to a colour: the lamp's amber or the ember red.
    func pixels(in bitmap: NSBitmapImageRep, near target: (r: CGFloat, g: CGFloat, b: CGFloat)) -> Int {
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                // The bitmap's own components: converting to another colour space moves red too far.
                guard let colour = bitmap.colorAt(x: x, y: y) else { continue }
                if abs(colour.redComponent - target.r) < 0.08, abs(colour.greenComponent - target.g) < 0.08, abs(colour.blueComponent - target.b) < 0.08 {
                    count += 1
                }
            }
        }
        return count
    }

    let amber = (r: CGFloat(1.0), g: CGFloat(0.70), b: CGFloat(0.16))
    let ember = (r: CGFloat(0.98), g: CGFloat(0.20), b: CGFloat(0.26))

    @Test func theFolderStepGrowsWithItsRowsAndSaysWhyItIsEmpty() async throws {
        let harness = try PaletteHarness()
        let model = harness.model
        let view = PaletteView(model: model, hover: HoverTracker(), drawsFields: false)
        #expect(view.emptyMessage == "Looking for repositories…")
        await model.begin()
        let full = try render(model, named: "palette-folder")
        model.setQuery("api")
        let two = try render(model, named: "palette-folder-two")
        model.setQuery("zzz")
        let none = try render(model, named: "palette-folder-none")
        #expect(full.pixelsWide == Int((PaletteView.width + 24) * 2))
        // Eight rows, two rows, and a line of explanation.
        #expect(full.pixelsHigh > two.pixelsHigh + 6 * 30 * 2)
        #expect(two.pixelsHigh > none.pixelsHigh)
        #expect(view.emptyMessage.contains("No session or repository matches “zzz”"))
        // The row with sessions carries the lamp's colour.
        #expect(pixels(in: full, near: amber) > 0)

        let empty = try PaletteHarness(names: [])
        await empty.model.begin()
        let emptyView = PaletteView(model: empty.model, hover: HoverTracker(), drawsFields: false)
        #expect(emptyView.emptyMessage.hasPrefix("No repositories yet."))
    }

    @Test func thePromptStepShowsOptionsOnlyWhenAskedAndOnlyWhatTheCLIHas() async throws {
        let harness = try PaletteHarness()
        await harness.ready()
        let plain = try render(harness.model, named: "palette-prompt")
        harness.model.showsOptions = true
        let withOptions = try render(harness.model, named: "palette-prompt-options")
        // Model, effort, agent, permissions and worktree: five rows.
        #expect(withOptions.pixelsHigh > plain.pixelsHigh + 5 * 24 * 2)
        harness.model.options.permissionMode = "acceptEdits"
        let withNote = try render(harness.model, named: "palette-prompt-accept-edits")
        #expect(withNote.pixelsHigh > withOptions.pixelsHigh)

        // An older CLI that only has --bg: the options area is there, with no rows in it.
        var old = DispatchCapabilities()
        old.background = true
        let limited = try PaletteHarness(capabilities: old)
        await limited.ready()
        limited.model.showsOptions = true
        let bare = try render(limited.model, named: "palette-prompt-old-cli")
        #expect(bare.pixelsHigh < plain.pixelsHigh + 2 * 24 * 2)
    }

    @Test func theResultIsAmberAndAFailureIsRed() async throws {
        let harness = try PaletteHarness()
        await harness.ready()
        await harness.model.start(open: false)
        let started = try render(harness.model, named: "palette-started")
        #expect(pixels(in: started, near: amber) > 0 && pixels(in: started, near: ember) == 0)

        let failing = try PaletteHarness()
        failing.probe.failure = .failed(.other("error: something long went wrong\nwith a second line of detail"), command: "claude --bg -- x")
        await failing.ready()
        await failing.model.start(open: false)
        let failed = try render(failing.model, named: "palette-failed")
        #expect(pixels(in: failed, near: ember) > 0 && pixels(in: failed, near: amber) == 0)
        // Two lines of the CLI's words make it taller than the one-line result.
        #expect(failed.pixelsHigh > started.pixelsHigh)
    }

    @Test func theInboxFooterOffersANewSession() throws {
        var pressed = 0
        var actions = InboxActions()
        actions.newSession = { pressed += 1 }
        actions.newSession()
        #expect(pressed == 1)
        let hover = HoverTracker(hovered: "footer.new")
        let plain = ImageRenderer(content: InboxView(snapshot: StoreSnapshot(), actions: actions, scrolls: false)).nsImage
        let hovered = ImageRenderer(content: InboxView(snapshot: StoreSnapshot(), actions: actions, hover: hover, scrolls: false)).nsImage
        // The button exists: hovering it changes what is drawn.
        let plainData = try #require(plain?.tiffRepresentation)
        let hoveredData = try #require(hovered?.tiffRepresentation)
        #expect(plainData != hoveredData)
    }
}

@MainActor
@Suite struct DispatchRefreshTests {
    actor Sessions {
        var rows: [SessionSummary] = []
        var reads = 0

        func add(_ row: SessionSummary) { rows.append(row) }

        func read() -> AgentsSnapshot {
            reads += 1
            return AgentsSnapshot(sessions: rows, skipped: 0)
        }
    }

    final class Opened: TerminalLauncher, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TerminalCommand] = []
        var commands: [TerminalCommand] { lock.withLock { stored } }

        func open(_ command: TerminalCommand) async -> LaunchOutcome {
            lock.withLock { stored.append(command) }
            return .opened(terminal: "Test")
        }
    }

    func model(_ sessions: Sessions, launcher: Opened) throws -> InboxModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-dispatch-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SessionStore(fetch: { await sessions.read() })
        let locator = ClaudeLocator(override: "/bin/echo", environment: [:], homeDirectory: "/nowhere")
        return InboxModel(
            store: store, launcher: launcher, locator: locator, settingsURL: Settings.fileURL(in: directory),
            remindersURL: ReminderState.fileURL(in: directory))
    }

    @Test func aStartedSessionIsInTheInboxBeforeAnyPoll() async throws {
        let sessions = Sessions()
        let launcher = Opened()
        let model = try model(sessions, launcher: launcher)
        // The model is not running: nothing polls.
        #expect(model.snapshot.sessions.isEmpty)

        // What `claude --bg` just did.
        await sessions.add(SessionSummary(id: "4cb41c2a", name: "fix-gap", cwd: "/Users/u/code/porchlight", state: .working))
        await model.sessionStarted(Dispatched(id: "4cb41c2a", name: "fix-gap", directory: "/Users/u/code/porchlight"), open: false)

        #expect(model.snapshot.sessions.map(\.id) == ["4cb41c2a"])
        #expect(await sessions.reads == 1)
        #expect(model.notice == "Started fix-gap (4cb41c2a)")
        #expect(model.sessionDirectories == ["/Users/u/code/porchlight"])
        #expect(launcher.commands.isEmpty)
    }

    @Test func dispatchAndOpenAttachesToTheNewSession() async throws {
        let sessions = Sessions()
        let launcher = Opened()
        let model = try model(sessions, launcher: launcher)
        await sessions.add(SessionSummary(id: "4cb41c2a", name: "fix-gap", cwd: "/Users/u/code/porchlight", state: .working))
        await model.sessionStarted(Dispatched(id: "4cb41c2a", name: "fix-gap", directory: "/Users/u/code/porchlight"), open: true)
        // The launch runs in its own task.
        for _ in 0..<200 where launcher.commands.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(launcher.commands.map(\.arguments) == [["/bin/echo", "attach", "4cb41c2a"]])
    }

    @Test func openingASessionLetsGoOfTheKeyboardFirst() async throws {
        let sessions = Sessions()
        let launcher = Opened()
        let model = try model(sessions, launcher: launcher)
        var snapshot = StoreSnapshot()
        snapshot.sessions = [Session(summary: SessionSummary(id: "aaaa1111", name: "one", cwd: "/Users/u/code/one", state: .blocked))]
        model.apply(snapshot)

        // What the app wires to closing the menu-bar panel, and what was launched by then.
        var launchedWhenAsked: [Int] = []
        model.willOpenTerminal = { launchedWhenAsked.append(launcher.commands.count) }
        model.open(sessionID: "aaaa1111")
        // Asked straight away, before the terminal is touched.
        #expect(launchedWhenAsked == [0])
        for _ in 0..<200 where launcher.commands.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(launcher.commands.count == 1)

        model.openAgentView()
        #expect(launchedWhenAsked == [0, 1])
    }

    @Test func trustingAFolderOpensPlainClaudeThereAndNothingElse() async throws {
        let launcher = Opened()
        let model = try model(Sessions(), launcher: launcher)
        model.openToTrust(folder: "/Users/u/code/new-repo")
        for _ in 0..<200 where launcher.commands.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let command = try #require(launcher.commands.first)
        // No flag that could answer or skip the prompt.
        #expect(command.arguments == ["/bin/echo"])
        #expect(command.cwd == "/Users/u/code/new-repo")
    }
}

/// Sessions as the inbox would list them: two that need the user, four working, one done.
@MainActor
enum PaletteSessions {
    static let now = PaletteHarness.now

    static func session(_ id: String, _ name: String, _ repo: String, _ state: SessionState, waited: TimeInterval = 600) -> Session {
        Session(
            summary: SessionSummary(id: id, name: name, cwd: "/Users/u/code/\(repo)", kind: "background", state: state),
            observedBlockedSince: state == .blocked ? now - waited : nil)
    }

    static func rows(snoozes: [String: Snooze] = [:]) throws -> [InboxRow] {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("PorchlightCoreTests/Fixtures")
        // One real fixture session with a question, options and a suggested reply.
        let json = try String(contentsOf: fixtures.appendingPathComponent("agents-all.json"), encoding: .utf8)
        let enriched = JobStateSource(jobsDirectory: fixtures.appendingPathComponent("jobs")).enrich(try AgentsCLISource.decode(json).sessions)
        let withReply = try #require(enriched.first { $0.needsHuman && $0.suggestedReply != nil })
        let sessions = [
            withReply,
            session("bbbb0002", "migrate billing tables", "billing", .blocked, waited: 3 * 3600),
            session("cccc0003", "refactor api client", "api-gateway", .working),
            session("cccc0004", "write docs index", "docs", .working),
            session("cccc0005", "bump dependencies", "infra", .working),
            session("cccc0006", "tidy website css", "website", .working),
            session("dddd0007", "old api cleanup", "api-gateway", .done),
        ]
        return InboxGroups(sessions: sessions, now: now, recentWindow: 10 * 365 * 86400)
            .sections(now: now, snoozes: snoozes, overdueAfter: 7200).flatMap(\.rows)
    }
}

@MainActor
@Suite struct PaletteSessionsTests {
    @Test func withNothingTypedWaitingSessionsComeFirstThenAFewWorkingThenRepositories() async throws {
        let harness = try PaletteHarness()
        harness.probe.rows = try PaletteSessions.rows()
        await harness.model.begin()
        let model = harness.model
        #expect(model.sessions.count == 7)
        // Both waiting ones, three of the four working ones, and not the finished one.
        #expect(model.sessionResults.map(\.kind.needsUser) == [true, true, false, false, false])
        #expect(model.sessionResults.count == 2 + PaletteModel.workingSessionsShown)
        #expect(!model.sessionResults.contains { $0.kind == .done })
        // The list is sessions, then every repository.
        #expect(model.items.count == 5 + 10)
        #expect(model.selectedSession?.kind.needsUser == true)
        #expect(model.selectedRepo == nil)
        if case .repo? = model.items.dropFirst(5).first {} else { Issue.record("repositories should follow the sessions") }
    }

    @Test func typingFiltersSessionsAndRepositoriesTogether() async throws {
        let harness = try PaletteHarness()
        harness.probe.rows = try PaletteSessions.rows()
        await harness.model.begin()
        let model = harness.model
        model.setQuery("api")
        // Sessions by their name or place, the finished one included now; then repositories.
        #expect(Set(model.sessionResults.prefix(2).map(\.id)) == ["cccc0003", "dddd0007"])
        #expect(!model.sessionResults.contains { $0.id == "bbbb0002" })
        #expect(model.results.map(\.name) == ["api-gateway", "payments-api"])
        #expect(model.items.count == model.sessionResults.count + 2)
        model.setQuery("billing")
        #expect(model.sessionResults.map(\.id) == ["bbbb0002"])
        #expect(model.results.map(\.name) == ["billing"])
        // A path is a folder to start in, never a session.
        model.setQuery("~/code/docs")
        #expect(model.sessionResults.isEmpty && model.results.map(\.name) == ["docs"])
        model.setQuery("zzzz")
        #expect(model.items.isEmpty && model.selectedItem == nil)
    }

    @Test func arrowsMoveFromSessionsIntoRepositoriesAndTheWindowFollows() async throws {
        let harness = try PaletteHarness()
        harness.probe.rows = try PaletteSessions.rows()
        await harness.model.begin()
        let model = harness.model
        model.moveSelection(by: 4)
        #expect(model.selectedSession == model.sessionResults.last)
        model.moveSelection(by: 1)
        #expect(model.selectedSession == nil && model.selectedRepo != nil)
        #expect(model.visibleItems.count == PaletteModel.visibleRows)
        model.moveSelection(by: 100)
        #expect(model.selectedItem == model.items.last)
        #expect(model.visibleItems.last == model.items.last)
        model.moveSelection(by: -100)
        #expect(model.selection == 0 && model.visibleItems.first == model.items.first)
    }

    @Test func withoutSessionsThePaletteIsTheRepositoryListItWas() async throws {
        let harness = try PaletteHarness()
        await harness.model.begin()
        #expect(harness.model.sessionResults.isEmpty)
        // "docs" has a session in the harness, which ranks it first.
        #expect(harness.model.items.count == 10 && harness.model.selectedRepo?.name == "docs")
    }

    @Test func headingsMarkWhereTheListChangesKind() throws {
        let rows = try PaletteSessions.rows()
        let session = PaletteModel.Item.session(rows[0])
        let repo = PaletteModel.Item.repo(Repo(path: "/Users/u/code/docs"))
        #expect(PaletteView.heading(for: session, after: nil) == "Sessions")
        #expect(PaletteView.heading(for: session, after: session) == nil)
        #expect(PaletteView.heading(for: repo, after: session) == "Start a new session in")
        #expect(PaletteView.heading(for: repo, after: repo) == nil)
        #expect(PaletteView.heading(for: repo, after: nil) == "Start a new session in")
    }
}

@MainActor
@Suite struct PaletteSessionActionsTests {
    final class Calls: @unchecked Sendable {
        var opened: [String] = []
        var copied: [String] = []
        var snoozed: [(String, SnoozeChoice)] = []
        var retried: [String] = []
    }

    func harness(snoozes: [String: Snooze] = [:], retryable: Bool = false) async throws -> (PaletteHarness, Calls) {
        let harness = try PaletteHarness()
        var rows = try PaletteSessions.rows(snoozes: snoozes)
        if retryable {
            // A session stopped on a rate limit, as the transient-failure patterns see it.
            let failed = Session(
                summary: SessionSummary(id: "eeee0008", name: "import customers", cwd: "/Users/u/code/billing", state: .blocked),
                observedBlockedSince: PaletteSessions.now - 300)
            let row = InboxRow(session: failed, now: PaletteSessions.now)
            rows.insert(row, at: 0)
        }
        harness.probe.rows = rows
        let calls = Calls()
        harness.model.onOpenSession = { calls.opened.append($0) }
        harness.model.onCopyReply = { calls.copied.append($0) }
        harness.model.onSnooze = { id, choice in
            calls.snoozed.append((id, choice))
            // What the inbox does: the row comes back marked as snoozed, or not.
            harness.probe.rows = try! PaletteSessions.rows(snoozes: choice == .wake ? [:] : [id: .until(PaletteSessions.now + 3600)])
        }
        harness.model.onRetry = { calls.retried.append($0) }
        await harness.model.begin()
        return (harness, calls)
    }

    @Test func returnOnASessionOpensItAndClosesThePalette() async throws {
        let (harness, calls) = try await harness()
        let model = harness.model
        model.moveSelection(by: 1)
        model.confirmFolder()
        #expect(calls.opened == ["bbbb0002"])
        #expect(harness.closed.values.count == 1)
        // Nothing was dispatched and the palette did not move on to a prompt.
        #expect(model.step == .folder && harness.probe.requests.isEmpty)
    }

    @Test func copyingTheReplyAlsoOpensTheSessionAndOnlyWhenThereIsAReply() async throws {
        let (harness, calls) = try await harness()
        let model = harness.model
        let first = try #require(model.selectedSession)
        #expect(first.suggestedReply != nil)
        model.copyReplyAndOpenSelected()
        #expect(calls.copied == [first.id] && calls.opened == [first.id])
        #expect(harness.closed.values.count == 1)

        // The next session suggests nothing: the key does nothing at all.
        model.moveSelection(by: 1)
        #expect(model.selectedSession?.suggestedReply == nil)
        model.copyReplyAndOpenSelected()
        #expect(calls.copied.count == 1 && calls.opened.count == 1)
    }

    @Test func snoozingKeepsThePaletteOpenAndTheSecondPressRemindsAgain() async throws {
        let (harness, calls) = try await harness()
        let model = harness.model
        model.moveSelection(by: 1)
        await model.snoozeSelected()
        #expect(calls.snoozed.count == 1 && calls.snoozed[0].0 == "bbbb0002" && calls.snoozed[0].1 == .hour)
        #expect(harness.closed.values.isEmpty)
        // The list was read again: the row is still there, now marked.
        #expect(model.selectedSession?.id == "bbbb0002" && model.selectedSession?.isSnoozed == true)
        await model.snoozeSelected()
        #expect(calls.snoozed.count == 2 && calls.snoozed[1].1 == .wake)
        #expect(model.selectedSession?.isSnoozed == false)
    }

    @Test func aWorkingSessionOrARepositoryCannotBeSnoozedOrRetried() async throws {
        let (harness, calls) = try await harness()
        let model = harness.model
        model.moveSelection(by: 2)
        #expect(model.selectedSession?.kind == .working)
        await model.snoozeSelected()
        model.retrySelected()
        model.copyReplyAndOpenSelected()
        model.moveSelection(by: 5)
        #expect(model.selectedRepo != nil)
        await model.snoozeSelected()
        model.retrySelected()
        model.copyReplyAndOpenSelected()
        #expect(calls.snoozed.isEmpty && calls.retried.isEmpty && calls.copied.isEmpty && calls.opened.isEmpty)
    }

    @Test func retryIsOfferedOnlyForASessionThatCanBeRetried() async throws {
        let (harness, calls) = try await harness()
        // No fixture session stopped on a passing failure.
        #expect(!harness.model.sessions.contains { $0.isRetryable })
        harness.model.retrySelected()
        #expect(calls.retried.isEmpty)
    }

    @Test func theActionsDoNothingOnceThePaletteHasMovedOnToAPrompt() async throws {
        let (harness, calls) = try await harness()
        let model = harness.model
        model.setQuery("docs")
        model.moveSelection(by: 1)
        model.confirmFolder()
        #expect(model.step == .prompt)
        model.copyReplyAndOpenSelected()
        await model.snoozeSelected()
        model.retrySelected()
        #expect(calls.copied.isEmpty && calls.snoozed.isEmpty && calls.retried.isEmpty)
    }
}

@MainActor
@Suite struct PaletteSessionViewTests {
    func height(_ model: PaletteModel, named name: String) throws -> Int {
        let view = PaletteView(model: model, hover: HoverTracker(), drawsFields: false)
        let renderer = ImageRenderer(content: view.padding(12).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        if let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return bitmap.pixelsHigh
    }

    @Test func sessionRowsAreTallerThanRepositoryRowsAndCarryAHeading() async throws {
        let plain = try PaletteHarness()
        await plain.model.begin()
        let reposOnly = try height(plain.model, named: "palette-repos-only")

        let harness = try PaletteHarness()
        harness.probe.rows = try PaletteSessions.rows()
        await harness.model.begin()
        let mixed = try height(harness.model, named: "palette-sessions")
        // Both show eight rows; five of the mixed ones are sessions, which have a second line,
        // and the mixed list has one more heading.
        #expect(mixed > reposOnly + 5 * 8 * 2)
    }

    @Test func aSessionSaysWhatItWantsOrWhatItIsDoing() throws {
        let rows = try PaletteSessions.rows()
        let hover = HoverTracker()
        let question = try #require(rows.first { $0.suggestedReply != nil })
        #expect(PaletteSessionRow(row: question, isSelected: false, hover: hover, open: {}).subtitle == question.detail)
        let waiting = try #require(rows.first { $0.id == "bbbb0002" })
        #expect(PaletteSessionRow(row: waiting, isSelected: false, hover: hover, open: {}).subtitle == "Waiting for you")
        let working = try #require(rows.first { $0.kind == .working })
        #expect(PaletteSessionRow(row: working, isSelected: false, hover: hover, open: {}).subtitle == "Working")
        let done = try #require(rows.first { $0.kind == .done })
        #expect(PaletteSessionRow(row: done, isSelected: false, hover: hover, open: {}).subtitle == "Done")
    }

    @Test func theBottomBarFollowsWhatIsSelected() async throws {
        let harness = try PaletteHarness()
        harness.probe.rows = try PaletteSessions.rows()
        await harness.model.begin()
        // A session with a reply: Open, Copy reply and open, Snooze. Then a repository: two hints.
        let onSession = try height(harness.model, named: "palette-session-selected")
        harness.model.moveSelection(by: 6)
        #expect(harness.model.selectedRepo != nil)
        let onRepo = try height(harness.model, named: "palette-repo-selected")
        // Same rows on screen, so the same height: only the bar's content changes.
        #expect(onSession == onRepo)
    }
}
