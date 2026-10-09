import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

/// Three notes: one whose session is still listed, one whose session was removed but can be
/// resumed, and one of which only the summary is left.
@MainActor
enum NotesWorld {
    static let day: TimeInterval = 86400

    static func note(_ id: String, _ name: String, repo: String, summary: String, age: TimeInterval, branch: String? = nil, folder: String? = nil, onDevice: Bool = false) -> SessionNote {
        var note = SessionNote(
            id: id, sessionID: "\(id)-0000-4000-8000-000000000000", name: name, repo: repo, directory: folder ?? "/Users/u/code/\(repo)", branch: branch,
            pullRequest: branch == nil ? nil : "PR #41 is open", summary: summary, model: onDevice ? WrapUp.onDeviceModelName : "haiku",
            createdAt: PaletteHarness.now - age)
        if onDevice {
            note.engine = .onDevice
            note.turnsRead = 12
            note.isPartial = true
        }
        return note
    }

    static let live = note("bbbb0002", "migrate billing tables", repo: "billing", summary: "Doing: moving invoices to the new schema.\nStopped at: asking which column to drop.\nWorth keeping: nothing.", age: 3 * day)
    static let removed = note(
        "dddd0009", "login bug", repo: "website", summary: "Doing: debugging the redirect loop after sign-in.\nStopped at: fix written, not tested on Safari.\nWorth keeping: the cookie SameSite finding.",
        age: 12 * day, branch: "fix/login-redirect", onDevice: true)
    static let gone = note("eeee0010", "budget for October", repo: "gone-repo", summary: "Doing: the October budget.\nStopped at: done.\nWorth keeping: nothing.", age: 40 * day)

    static func harness(notes: [SessionNote]? = nil) throws -> PaletteHarness {
        let harness = try PaletteHarness()
        harness.probe.rows = try PaletteSessions.rows()
        harness.probe.notes = notes ?? [live, removed, gone]
        // Claude Code still has the first two conversations; the third's folder is not there either.
        harness.probe.conversations = [live.sessionID, removed.sessionID]
        return harness
    }
}

@MainActor
@Suite struct PaletteNotesModelTests {
    @Test func tabGoesToTheNotesAndBackWithWhatWasTyped() async throws {
        let harness = try NotesWorld.harness()
        let model = harness.model
        await model.begin()
        let focus = model.focusRequest
        model.setQuery("login")
        model.toggleNotes()
        #expect(model.step == .notes && model.query == "login" && model.focusRequest == focus + 1)
        #expect(model.noteResults.map(\.id) == ["dddd0009"] && model.selectedNote == NotesWorld.removed)
        model.setQuery("billing")
        model.toggleNotes()
        // Back among sessions and repositories, searching for the same thing.
        #expect(model.step == .folder && model.query == "billing" && model.selectedSession?.id == "bbbb0002")
        // Tab means nothing while a prompt is being written.
        model.setQuery("porch")
        model.confirmFolder()
        #expect(model.step == .prompt)
        model.toggleNotes()
        #expect(model.step == .prompt)
    }

    @Test func notesAreSearchedAsTypedAndNewestFirstWhenNothingIs() async throws {
        let harness = try NotesWorld.harness()
        let model = harness.model
        await model.begin()
        model.toggleNotes()
        #expect(model.noteResults.map(\.id) == ["bbbb0002", "dddd0009", "eeee0010"] && model.noteSelection == 0)
        model.setQuery("safari")
        #expect(model.noteResults.map(\.id) == ["dddd0009"])
        model.setQuery("doing website")
        #expect(model.noteResults.map(\.id) == ["dddd0009"])
        model.setQuery("fix/login")
        #expect(model.noteResults.map(\.id) == ["dddd0009"])
        model.setQuery("kubernetes")
        #expect(model.noteResults.isEmpty && model.selectedNote == nil)
        // Nothing selected: the keys do nothing.
        model.confirmNote()
        model.copySelectedNote()
        model.askDeleteSelectedNote()
        #expect(harness.closed.values.isEmpty && harness.copied.values.isEmpty && model.pendingNoteDeletion == nil)
    }

    @Test func theArrowKeysChooseTheNoteThatIsShown() async throws {
        let many = (0..<9).map { NotesWorld.note(String(format: "aaaa%04d", $0), "note \($0)", repo: "docs", summary: "s\($0)", age: Double($0) * 3600) }
        let harness = try NotesWorld.harness(notes: many)
        let model = harness.model
        await model.begin()
        model.toggleNotes()
        #expect(model.selectedNote?.name == "note 0" && model.visibleNoteResults.count == PaletteModel.visibleNotes)
        model.moveNoteSelection(by: -1)
        #expect(model.noteSelection == 0)
        for _ in 0..<6 { model.moveNoteSelection(by: 1) }
        // The window follows the selection.
        #expect(model.selectedNote?.name == "note 6" && model.visibleNoteResults.map(\.name) == ["note 2", "note 3", "note 4", "note 5", "note 6"])
        model.moveNoteSelection(by: 50)
        #expect(model.selectedNote?.name == "note 8")
        model.select(many[3])
        #expect(model.selectedNote?.name == "note 3")
        // Typing starts from the top again.
        model.setQuery("note")
        #expect(model.noteSelection == 0)
    }

    @Test func theOrdinaryListCountsNotesWithoutListingThem() async throws {
        let harness = try NotesWorld.harness()
        let model = harness.model
        await model.begin()
        let before = model.items
        #expect(model.notesOnOffer == 3)
        #expect(PaletteView.notesLine(count: 3, searching: false) == "3 notes kept from sessions you wrapped up")
        model.setQuery("login")
        #expect(model.notesOnOffer == 1 && PaletteView.notesLine(count: 1, searching: true) == "1 note matches")
        #expect(PaletteView.notesLine(count: 2, searching: true) == "2 notes match")
        // No note is ever an item of the list, and a path is not a search for notes.
        #expect(!model.items.contains { $0.id.contains("dddd0009") })
        model.setQuery("~/code")
        #expect(model.notesOnOffer == 0)
        model.setQuery("")
        #expect(model.items == before)

        let none = try NotesWorld.harness(notes: [])
        await none.model.begin()
        #expect(none.model.notesOnOffer == 0)
        none.model.toggleNotes()
        #expect(none.model.step == .notes && none.model.noteResults.isEmpty)
    }

    @Test func escapeGoesBackOrClosesDependingOnHowTheNotesWereOpened() async throws {
        let harness = try NotesWorld.harness()
        let model = harness.model
        await model.begin()
        model.toggleNotes()
        model.escape()
        #expect(model.step == .folder && harness.closed.values.isEmpty)
        // From the Triage tab the palette opens on its notes; Escape then closes it.
        await model.beginOnNotes()
        #expect(model.step == .notes && model.noteResults.count == 3)
        model.escape()
        #expect(harness.closed.values.count == 1)
        // Opened the ordinary way again, it is the ordinary palette.
        await model.begin()
        #expect(model.step == .folder && model.pendingNoteDeletion == nil)
    }
}

@MainActor
@Suite struct PaletteNotesActionTests {
    @Test func returnDoesTheMostThatCanStillBeDone() async throws {
        let harness = try NotesWorld.harness()
        let model = harness.model
        var openedSessions: [String] = []
        var resumed: [SessionNote] = []
        model.onOpenSession = { openedSessions.append($0) }
        model.onResume = { resumed.append($0) }
        await model.begin()
        model.toggleNotes()

        #expect(model.reach(of: NotesWorld.live) == .session && model.noteVerb == "Open the session")
        model.confirmNote()
        #expect(openedSessions == ["bbbb0002"] && resumed.isEmpty && harness.closed.values.count == 1)

        model.moveNoteSelection(by: 1)
        #expect(model.reach(of: NotesWorld.removed) == .conversation && model.noteVerb == "Resume in terminal")
        model.confirmNote()
        #expect(resumed == [NotesWorld.removed] && openedSessions.count == 1 && harness.closed.values.count == 2)

        // Only the summary is left: it is copied, and the palette stays for the next note.
        model.moveNoteSelection(by: 1)
        #expect(model.reach(of: NotesWorld.gone) == .summaryOnly && model.noteVerb == "Copy summary")
        model.confirmNote()
        #expect(harness.copied.values == ["budget for October (gone-repo)\nDoing: the October budget.\nStopped at: done.\nWorth keeping: nothing."])
        #expect(model.noteMessage == "Summary copied." && harness.closed.values.count == 2 && resumed.count == 1)
    }

    @Test func aConversationIsOnlyResumedWhileItAndItsFolderAreThere() {
        let note = NotesWorld.removed
        let reach = { (live: Set<String>, conversation: Bool, folder: Bool) in
            NoteReach.of(note, liveSessionIDs: live, conversationExists: { _ in conversation }, folderExists: { _ in folder })
        }
        #expect(reach(["dddd0009"], false, false) == .session)
        #expect(reach([], true, true) == .conversation)
        #expect(reach([], true, false) == .summaryOnly && reach([], false, true) == .summaryOnly)
        #expect(NoteReach.session.label == "still here" && NoteReach.conversation.label == "removed" && NoteReach.summaryOnly.label == "only this note is left")
    }

    @Test func theResumeCommandIsBuiltFromAValidatedId() throws {
        let command = try #require(TerminalCommand.resume(NotesWorld.removed, claude: "/opt/claude"))
        #expect(command.arguments == ["/opt/claude", "--resume", "dddd0009-0000-4000-8000-000000000000"])
        #expect(command.cwd == "/Users/u/code/website" && command.title == "login bug" && command.sessionID == nil && !command.opensAgentView)
        for bad in ["--dangerously-skip-permissions", "", "dddd0009", "x; rm -rf ~"] {
            let note = SessionNote(id: "a", sessionID: bad, name: "n", repo: "r", directory: "/d", summary: "s", model: "haiku", createdAt: PaletteHarness.now)
            #expect(TerminalCommand.resume(note, claude: "claude") == nil)
        }
        let nowhere = SessionNote(id: "a", sessionID: NotesWorld.removed.sessionID, name: "n", repo: "r", directory: "", summary: "s", model: "haiku", createdAt: PaletteHarness.now)
        #expect(TerminalCommand.resume(nowhere, claude: "claude") == nil)
    }

    @Test func copyingTakesTheSummaryWithWhereItWasFrom() async throws {
        let harness = try NotesWorld.harness()
        let model = harness.model
        await model.begin()
        model.setQuery("login")
        // In the ordinary list the key keeps its old meaning.
        model.copySelectedNote()
        #expect(harness.copied.values.isEmpty)
        model.toggleNotes()
        model.copySelectedNote()
        #expect(harness.copied.values == ["login bug (website, fix/login-redirect)\n" + NotesWorld.removed.summary])
        #expect(harness.closed.values.isEmpty && model.noteMessage == "Summary copied.")
        // Moving on clears what was said about the last one.
        model.setQuery("")
        #expect(model.noteMessage == nil)
    }

    @Test func deletingAsksFirstAndRemovesOnlyThatNote() async throws {
        let harness = try NotesWorld.harness()
        let model = harness.model
        await model.begin()
        model.toggleNotes()
        model.moveNoteSelection(by: 1)
        model.askDeleteSelectedNote()
        #expect(model.pendingNoteDeletion == NotesWorld.removed && harness.probe.deleted.isEmpty)
        // Escape, moving on or typing: the question goes and nothing is deleted.
        model.escape()
        #expect(model.pendingNoteDeletion == nil && model.step == .notes)
        model.askDeleteSelectedNote()
        model.moveNoteSelection(by: 1)
        #expect(model.pendingNoteDeletion == nil)
        model.askDeleteSelectedNote()
        model.setQuery("b")
        #expect(model.pendingNoteDeletion == nil && harness.probe.deleted.isEmpty)
        model.setQuery("")

        model.moveNoteSelection(by: 1)
        model.askDeleteSelectedNote()
        model.confirmNote()
        #expect(harness.probe.deleted == ["dddd0009"])
        #expect(model.noteResults.map(\.id) == ["bbbb0002", "eeee0010"] && model.noteMessage == "Deleted the note about login bug.")
        // Return deleted the note and did nothing else: no session opened, nothing resumed, palette open.
        #expect(harness.closed.values.isEmpty && model.selectedNote?.id == "eeee0010")

        // On disk: only that file goes.
        let archive = NotesArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-notes-\(UUID().uuidString)"))
        try archive.save(NotesWorld.live)
        try archive.save(NotesWorld.removed)
        try archive.delete("dddd0009")
        #expect(archive.all().map(\.id) == ["bbbb0002"])
        #expect(throws: (any Error).self) { try archive.delete("dddd0009") }
        #expect(throws: (any Error).self) { try archive.delete("../bbbb0002") }
        #expect(archive.all().count == 1)
    }
}

@MainActor
@Suite struct PaletteNotesViewTests {
    func height(_ model: PaletteModel, named name: String) throws -> CGFloat {
        let view = PaletteView(model: model, hover: HoverTracker(), drawsFields: false)
        let renderer = ImageRenderer(content: view.padding(12).background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        if let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return image.size.height
    }

    @Test func theNotesViewIsDrawnWithTheSelectedNoteInFull() async throws {
        let harness = try NotesWorld.harness()
        let model = harness.model
        await model.begin()
        let ordinary = try height(model, named: "palette-with-notes-line")
        model.toggleNotes()
        model.moveNoteSelection(by: 1)
        let notes = try height(model, named: "palette-notes")
        #expect(notes > 250)

        model.askDeleteSelectedNote()
        #expect(try height(model, named: "palette-notes-delete") > notes + 20)
        model.escape()

        model.setQuery("kubernetes")
        let empty = try height(model, named: "palette-notes-empty")
        #expect(empty < notes - 100)
        #expect(PaletteView(model: model, hover: HoverTracker()).notesEmptyMessage == "No note matches “kubernetes”.")

        // Without notes the ordinary list has no line about them.
        let none = try NotesWorld.harness(notes: [])
        await none.model.begin()
        #expect(try height(none.model, named: "palette-no-notes") < ordinary)
        none.model.toggleNotes()
        #expect(PaletteView(model: none.model, hover: HoverTracker()).notesEmptyMessage.hasPrefix("No notes yet. Wrap up a session in the Triage tab"))
    }

    @Test func aRowSaysWhereItsSessionStandsAndTheSummarySaysWhoWroteIt() {
        #expect(PaletteNoteRow.age(NotesWorld.removed, now: PaletteHarness.now) == "12d ago")
        #expect(PaletteNoteRow.age(NotesWorld.removed, now: NotesWorld.removed.createdAt) == "just now")
        #expect(PaletteView.provenance(of: NotesWorld.removed) == "fix/login-redirect, PR #41 is open, summarised on this Mac from the first request and the last 11 turns")
        #expect(PaletteView.provenance(of: NotesWorld.gone) == "summarised with haiku")
    }

    @Test func theTriageTabOffersTheWayInWhenThereAreNotes() throws {
        var calls = 0
        var actions = InboxActions()
        actions.showsTriage = true
        actions.showNotes = { calls += 1 }
        actions.triage.hasLoaded = true
        func height() throws -> CGFloat {
            let view = InboxView(snapshot: StoreSnapshot(), now: PaletteHarness.now, actions: actions, scrolls: false)
            return try #require(ImageRenderer(content: view.background(Color.white)).nsImage).size.height
        }
        let without = try height()
        actions.triage.notes = ["dddd0009": NotesWorld.removed]
        // With nothing safe to remove the link is the only button, on a line of its own.
        let with = try height()
        #expect(with > without && with < without + 40)
        #expect(TriagePage.notesLink(1) == "1 note" && TriagePage.notesLink(12) == "12 notes")
        actions.showNotes()
        #expect(calls == 1)
    }
}
