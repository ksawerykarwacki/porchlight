import Foundation
import PorchlightCore

func printNote(_ note: SessionNote) {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    var heading = "\(note.id)  \(note.name)  [\(note.repo)]"
    if let branch = note.branch { heading += "  \(branch)" }
    if let pullRequest = note.pullRequest { heading += "  \(pullRequest)" }
    print(heading)
    print("  summarised \(formatter.string(from: note.createdAt)) with \(note.model)")
    for line in note.summary.split(separator: "\n", omittingEmptySubsequences: false) {
        print("  \(line)")
    }
    print("  to open it again: \(note.resumeCommand)")
}

func printNotes(_ notes: [SessionNote]) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(["notes": notes]) else { fail("could not encode the notes") }
    print(String(decoding: data, as: UTF8.self))
}

/// `porchlight wrap-up <id> [--model MODEL] [--json]`: summarise a session with a small model and
/// keep the summary as a note. Asking for it is the consent: it reads the whole conversation and
/// uses Claude usage.
func wrapUp(arguments: [String]) async {
    var rest = arguments
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    var model: String?
    if let index = rest.firstIndex(of: "--model"), index + 1 < rest.count {
        model = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
    }
    guard rest.count == 1, let id = rest.first, !id.hasPrefix("-") else {
        fail("usage: porchlight wrap-up <id> [--model MODEL] [--json]", code: 2)
    }
    let locator = claudeLocator()
    guard let claude = locator.locate() else { fail(describe(.claudeNotFound(candidates: locator.candidates()))) }
    let store = liveStore()
    await store.refresh()
    let snapshot = await store.snapshot
    if let problem = snapshot.problem { fail(describe(problem)) }
    guard let session = snapshot.sessions.first(where: { $0.id == id }) else { fail("no session has the id \(id)") }

    let facts = await TriageGatherer().facts(for: session)
    let result = await SessionSummariser(claude: claude).wrapUp(
        session, model: model ?? (Settings.load().wrapUp ?? WrapUpSettings()).model, archive: NotesArchive(), branch: facts.branch,
        pullRequest: facts.branch == nil ? nil : facts.pullRequest.summary)
    switch result {
    case .failure(let failure):
        fail(failure.message)
    case .success(let note):
        json ? printNotes([note]) : printNote(note)
    }
}

/// `porchlight notes [--json] [TEXT]`: the summaries kept so far, newest first, or the ones
/// containing every word of TEXT. Notes outlive their sessions.
func notes(arguments: [String]) {
    var rest = arguments
    let json = rest.contains("--json")
    rest.removeAll { $0 == "--json" }
    if let flag = rest.first(where: { $0.hasPrefix("-") }) { fail("unknown option: \(flag)\nusage: porchlight notes [--json] [TEXT]", code: 2) }
    let found = NotesArchive().search(rest.joined(separator: " "))
    if json {
        printNotes(found)
        return
    }
    if found.isEmpty {
        print(rest.isEmpty ? "No notes yet. porchlight wrap-up <id> summarises a session and keeps the summary here." : "No note matches.")
        return
    }
    for (index, note) in found.enumerated() {
        if index > 0 { print("") }
        printNote(note)
    }
}
