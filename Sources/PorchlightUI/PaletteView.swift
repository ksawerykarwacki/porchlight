import PorchlightCore
import SwiftUI

/// The launcher palette's content: a card that shows one step at a time.
public struct PaletteView: View {
    public static let width: CGFloat = 640

    let model: PaletteModel
    let hover: HoverTracker
    /// Off for offscreen rendering, which cannot draw AppKit text fields or system pickers.
    let drawsFields: Bool
    let browse: () -> Void
    let addRoot: () -> Void

    public init(
        model: PaletteModel, hover: HoverTracker, drawsFields: Bool = true, browse: @escaping () -> Void = {}, addRoot: @escaping () -> Void = {}
    ) {
        self.model = model
        self.hover = hover
        self.drawsFields = drawsFields
        self.browse = browse
        self.addRoot = addRoot
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.step {
            case .folder: folderStep
            case .notes: notesStep
            case .prompt: promptStep
            case .starting: starting
            case .started(let started): result(started)
            case .failed(let message, let command, let untrustedFolder):
                failure(message: message, hasCommand: command != nil, untrustedFolder: untrustedFolder)
            }
        }
        .frame(width: Self.width)
        .modifier(PaletteSurface(glass: drawsFields))
    }

    // MARK: Folder

    @ViewBuilder private var folderStep: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            field(
                text: model.query, placeholder: "Session, repository, or a folder path", size: 20,
                onChange: model.setQuery, onMove: model.moveSelection, onSubmit: model.confirmFolder,
                onAlternateSubmit: { Task { await model.snoozeSelected() } }, onTab: model.toggleNotes)
        }
        .padding(.horizontal, 18)
        .frame(height: 56)
        Divider()

        if model.items.isEmpty {
            Text(emptyMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let visible = Array(model.visibleItems)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { position, item in
                    // A heading where the list turns from one kind of thing to the other.
                    if let heading = Self.heading(for: item, after: position > 0 ? visible[position - 1] : nil) {
                        Text(heading)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 18)
                            .padding(.top, position == 0 ? 2 : 8)
                            .padding(.bottom, 3)
                    }
                    switch item {
                    case .session(let row):
                        let isSelected = item == model.selectedItem
                        PaletteSessionRow(
                            row: row, isSelected: isSelected, hover: hover,
                            answers: isSelected && model.pendingControl == nil && model.canAnswer(row), chosen: model.chosenOption(for: row),
                            choose: model.chooseAnswer
                        ) { model.open(row) }
                    case .repo(let repo):
                        PaletteRepoRow(
                            repo: repo, isSelected: item == model.selectedItem, home: NSHomeDirectory(), hover: hover,
                            choose: { model.choose(repo) }, togglePin: { model.togglePin(repo) })
                    }
                }
            }
            .padding(.vertical, 6)
        }

        // The way to the kept summaries: one quiet line, never a row among the results.
        if model.notesOnOffer > 0 {
            Button(action: model.toggleNotes) {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 11))
                    Text(Self.notesLine(count: model.notesOnOffer, searching: !model.query.trimmingCharacters(in: .whitespaces).isEmpty))
                        .font(.system(size: 12))
                    Text("⇥")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.09)))
                    Spacer()
                }
                .foregroundStyle(hover.hovered == "palette.notes" ? .primary : .secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover.set("palette.notes", $0) }
        }

        if let note = model.pendingControl?.question ?? model.controlMessage {
            Divider()
            // The question before a stop or removal, or what came of the last one; a refusal is
            // Claude Code's own text.
            Text(note)
                .font(.system(size: 12.5))
                .foregroundStyle(model.pendingControl == nil ? .secondary : .primary)
                .lineLimit(10)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider()
        HStack(spacing: 2) {
            if let pending = model.pendingControl {
                KeyHint(keys: "↩", label: pending.verb, id: "palette.hint.choose", hover: hover, prominent: true, action: model.confirmFolder)
                KeyHint(keys: "esc", label: "Cancel", id: "palette.hint.close", hover: hover, action: model.escape)
            } else if let row = model.selectedSession, let chosen = model.chosenOption(for: row), row.options.indices.contains(chosen) {
                KeyHint(keys: "↩", label: AnswerBar.sendTitle(row.options[chosen]), id: "palette.hint.choose", hover: hover, prominent: true, action: model.confirmFolder)
                KeyHint(keys: "esc", label: "Cancel", id: "palette.hint.close", hover: hover, action: model.escape)
            } else if let row = model.selectedSession {
                KeyHint(keys: "↩", label: "Open", id: "palette.hint.choose", hover: hover, action: model.confirmFolder)
                if row.suggestedReply != nil {
                    KeyHint(keys: "⌘↩", label: "Copy reply, open", id: "palette.hint.reply", hover: hover, action: model.copyReplyAndOpenSelected)
                }
                if row.isRetryable {
                    KeyHint(keys: "⌘R", label: "Retry", id: "palette.hint.retry", hover: hover, action: model.retrySelected)
                }
                if row.kind.needsUser {
                    KeyHint(keys: "⌥↩", label: row.isSnoozed ? "Remind again" : "Snooze 1h", id: "palette.hint.snooze", hover: hover) {
                        Task { await model.snoozeSelected() }
                    }
                }
                KeyHint(keys: "⌘P", label: row.isPinned ? "Unpin" : "Pin", id: "palette.hint.pin", hover: hover) {
                    Task { await model.togglePinSelected() }
                }
                if row.canStop {
                    KeyHint(keys: "⌘S", label: "Stop", id: "palette.hint.stop", hover: hover) { model.askControlSelected(.stop) }
                }
                if row.canRemove {
                    KeyHint(keys: "⌘D", label: "Remove", id: "palette.hint.remove", hover: hover) { model.askControlSelected(.remove) }
                }
            } else {
                KeyHint(keys: "↩", label: "New session here", id: "palette.hint.choose", hover: hover, action: model.confirmFolder)
                KeyHint(keys: "esc", label: "Close", id: "palette.hint.close", hover: hover, action: model.escape)
            }
            Spacer()
            // The folder buttons give way to a session's actions: the bar has room for one set.
            if model.selectedSession == nil {
                if model.canRepeatLast {
                    QuietButton(title: "Same as last time", symbol: "arrow.uturn.backward", id: "palette.repeat", hover: hover, action: model.repeatLast)
                }
                QuietButton(title: "Add workspace folder…", symbol: "folder.badge.plus", id: "palette.root", hover: hover, action: addRoot)
                QuietButton(title: "Browse…", symbol: nil, id: "palette.browse", hover: hover, action: browse)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    static func notesLine(count: Int, searching: Bool) -> String {
        let notes = "\(count) \(count == 1 ? "note" : "notes")"
        return searching ? "\(notes) \(count == 1 ? "matches" : "match")" : "\(notes) kept from sessions you wrapped up"
    }

    // MARK: Notes

    @ViewBuilder private var notesStep: some View {
        HStack(spacing: 10) {
            Button(action: model.toggleNotes) {
                HStack(spacing: 5) {
                    Image(systemName: "note.text")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Notes")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Lamp.light.opacity(hover.hovered == "palette.notes.chip" ? 0.42 : 0.30)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hover.set("palette.notes.chip", $0) }
            .help("Back to sessions and repositories")
            field(
                text: model.query, placeholder: "Search what your wrapped-up sessions were about", size: 20,
                onChange: model.setQuery, onMove: model.moveNoteSelection, onSubmit: model.confirmNote, onTab: model.toggleNotes)
        }
        .padding(.horizontal, 14)
        .frame(height: 56)
        Divider()

        if model.noteResults.isEmpty {
            Text(notesEmptyMessage)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.visibleNoteResults)) { note in
                    PaletteNoteRow(
                        note: note, reach: model.reach(of: note), now: model.now, isSelected: note == model.selectedNote, hover: hover,
                        select: { model.select(note) })
                }
            }
            .padding(.vertical, 6)
            Divider()
            // The selected note in full: reading takes arrow keys and nothing else.
            if let note = model.selectedNote {
                VStack(alignment: .leading, spacing: 8) {
                    Text(note.summary)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .lineLimit(12)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.provenance(of: note))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        if let message = model.pendingNoteDeletion.map({ "Delete the note about \($0.name)? The session and its conversation are not touched." }) ?? model.noteMessage {
            Divider()
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(model.pendingNoteDeletion == nil ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        Divider()
        HStack(spacing: 2) {
            if model.pendingNoteDeletion != nil {
                KeyHint(keys: "↩", label: "Delete note", id: "palette.hint.choose", hover: hover, prominent: true, action: model.confirmNote)
                KeyHint(keys: "esc", label: "Cancel", id: "palette.hint.close", hover: hover, action: model.escape)
            } else if model.selectedNote != nil {
                KeyHint(keys: "↩", label: model.noteVerb, id: "palette.hint.choose", hover: hover, action: model.confirmNote)
                if model.noteVerb != "Copy summary" {
                    KeyHint(keys: "⌘↩", label: "Copy summary", id: "palette.hint.reply", hover: hover, action: model.copySelectedNote)
                }
                KeyHint(keys: "⌘D", label: "Delete note", id: "palette.hint.remove", hover: hover, action: model.askDeleteSelectedNote)
            }
            Spacer()
            KeyHint(keys: "⇥", label: "Sessions", id: "palette.hint.back", hover: hover, action: model.toggleNotes)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    var notesEmptyMessage: String {
        if model.notes.isEmpty {
            return "No notes yet. Wrap up a session in the Triage tab and its summary is kept here, also after the session is removed."
        }
        return "No note matches “\(model.query)”."
    }

    /// Where a note's session was and who summarised it, under the summary.
    static func provenance(of note: SessionNote) -> String {
        var parts: [String] = []
        if let branch = note.branch { parts.append(branch) }
        if let pullRequest = note.pullRequest { parts.append(pullRequest) }
        parts.append("summarised \(note.source)")
        return parts.joined(separator: ", ")
    }

    /// The heading above an item, when it is the first of its kind on screen.
    static func heading(for item: PaletteModel.Item, after previous: PaletteModel.Item?) -> String? {
        switch (item, previous) {
        case (.session, nil): "Sessions"
        case (.repo, nil), (.repo, .session?): "Start a new session in"
        default: nil
        }
    }

    var emptyMessage: String {
        if !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return "No session or repository matches “\(model.query)”. Type a folder path, or Browse."
        }
        if model.isLoading { return "Looking for repositories…" }
        return "No repositories yet. Add the folder your repositories live in and Porchlight will find them."
    }

    // MARK: Prompt

    @ViewBuilder private var promptStep: some View {
        HStack(spacing: 8) {
            Button(action: model.back) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(model.folder?.name ?? "")
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(hover.hovered == "palette.back" ? 0.12 : 0.07)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hover.set("palette.back", $0) }
            .help("Pick another folder")
            if let branch = model.branch {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(model.folder?.displayPath() ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)

        promptField
            .frame(height: 112)
            .padding(.horizontal, 14)

        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Name")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            field(text: model.name, placeholder: "Named by Claude Code", size: 13, onChange: model.setName, focuses: false)
            if model.editedName != nil {
                QuietButton(title: "Use the suggested name", symbol: nil, id: "palette.name.reset", hover: hover) { model.setName("") }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)

        if model.showsOptions {
            Divider()
            options
        }

        Divider()
        HStack(spacing: 2) {
            QuietButton(
                title: model.showsOptions ? "Fewer options" : "Options", symbol: model.showsOptions ? "chevron.up" : "chevron.down",
                id: "palette.options", hover: hover
            ) { model.showsOptions.toggle() }
            Spacer()
            KeyHint(keys: "⇧⌘↩", label: "Start and open", id: "palette.hint.startopen", hover: hover) { Task { await model.start(open: true) } }
                .opacity(model.canStart ? 1 : 0.45)
            KeyHint(keys: "⌘↩", label: "Start", id: "palette.hint.start", hover: hover, prominent: true) { Task { await model.start(open: false) } }
                .opacity(model.canStart ? 1 : 0.45)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var promptField: some View {
        if drawsFields {
            PalettePromptField(
                text: model.prompt, focusRequest: model.focusRequest, onChange: model.setPrompt,
                onSubmit: { open in Task { await model.start(open: open) } }, onCancel: model.escape
            )
            .overlay(alignment: .topLeading) {
                if model.prompt.isEmpty {
                    Text("What should Claude do here?")
                        .font(.system(size: 15))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
        } else {
            Text(model.prompt.isEmpty ? "What should Claude do here?" : model.prompt)
                .font(.system(size: 15))
                .foregroundStyle(model.prompt.isEmpty ? .tertiary : .primary)
                .padding(.leading, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder private var options: some View {
        let capabilities = model.capabilities
        VStack(alignment: .leading, spacing: 0) {
            if capabilities.model {
                optionRow("Model") {
                    field(text: model.options.model, placeholder: "Claude Code's default", size: 13, onChange: { model.options.model = $0 }, focuses: false)
                }
            }
            if !capabilities.effortLevels.isEmpty {
                optionRow("Effort") {
                    choice([nil] + capabilities.effortLevels.map(Optional.some), selected: model.options.effort) { model.options.effort = $0 }
                }
            }
            if capabilities.agent {
                optionRow("Agent") {
                    field(text: model.options.agent, placeholder: "None", size: 13, onChange: { model.options.agent = $0 }, focuses: false)
                }
            }
            if !capabilities.offeredPermissionModes.isEmpty {
                optionRow("Permissions") {
                    choice([nil] + capabilities.offeredPermissionModes.map(Optional.some), selected: model.options.permissionMode) {
                        model.options.permissionMode = $0
                    }
                }
                if model.options.permissionMode == "acceptEdits" {
                    Text("Edits are accepted without asking. Shell commands such as git commit still stop and ask.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 96)
                        .padding(.bottom, 4)
                }
            }
            if capabilities.worktree {
                optionRow("Worktree") {
                    if drawsFields {
                        Toggle("", isOn: Binding(get: { model.options.usesWorktree }, set: { model.options.usesWorktree = $0 }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    } else {
                        Text(model.options.usesWorktree ? "On" : "Off")
                            .font(.system(size: 13))
                    }
                    if model.options.usesWorktree {
                        field(text: model.options.worktreeName, placeholder: "Named by Claude Code", size: 13, onChange: { model.options.worktreeName = $0 }, focuses: false)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    private func optionRow(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
    }

    // MARK: Outcome

    private var starting: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Lamp.light)
                .frame(width: 9, height: 9)
            Text("Starting \(model.name.isEmpty ? "the session" : model.name)…")
                .font(.system(size: 15))
        }
        .padding(.horizontal, 18)
        .frame(height: 64)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func result(_ started: Dispatched) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Lamp.light)
                    .frame(width: 9, height: 9)
                Text("Started \(started.name ?? "a session")")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
            }
            Text("\(started.id) in \(RepoPath.abbreviated(started.directory))")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 19)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
        HStack(spacing: 2) {
            KeyHint(keys: "↩", label: "Done", id: "palette.hint.done", hover: hover, action: model.confirm)
            Spacer()
            QuietButton(title: "Open in terminal", symbol: "terminal", id: "palette.open", hover: hover, action: model.openStarted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func failure(message: String, hasCommand: Bool, untrustedFolder: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Lamp.ember)
                    .frame(width: 9, height: 9)
                Text(untrustedFolder == nil ? "The session did not start" : "Claude Code does not know this folder yet")
                    .font(.system(size: 15, weight: .semibold))
            }
            // The CLI's own words, unchanged.
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .lineLimit(10)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 19)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        Divider()
        HStack(spacing: 2) {
            KeyHint(keys: "↩", label: "Back to the prompt", id: "palette.hint.back", hover: hover, action: model.confirm)
            Spacer()
            if hasCommand {
                QuietButton(title: "Copy command", symbol: "doc.on.doc", id: "palette.copy", hover: hover, action: model.copyFailedCommand)
            }
            if untrustedFolder != nil {
                QuietButton(title: "Open Claude Code there", symbol: "terminal", id: "palette.trust", hover: hover, action: model.trustFolder)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // MARK: Controls

    /// A one-line text field. Offscreen it is drawn as its text.
    @ViewBuilder
    private func field(
        text: String, placeholder: String, size: CGFloat, onChange: @escaping (String) -> Void, onMove: @escaping (Int) -> Void = { _ in },
        onSubmit: @escaping () -> Void = {}, onAlternateSubmit: @escaping () -> Void = {}, onTab: (() -> Void)? = nil, focuses: Bool = true
    ) -> some View {
        if drawsFields {
            PaletteTextField(
                text: text, placeholder: placeholder, fontSize: size, focusRequest: focuses ? model.focusRequest : nil,
                onChange: onChange, onMove: onMove, onSubmit: onSubmit, onAlternateSubmit: onAlternateSubmit, onCancel: model.escape, onTab: onTab)
        } else {
            Text(text.isEmpty ? placeholder : text)
                .font(.system(size: size))
                .foregroundStyle(text.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A pop-up of choices where nil is "leave it to Claude Code".
    @ViewBuilder
    private func choice(_ values: [String?], selected: String?, set: @escaping (String?) -> Void) -> some View {
        let label: (String?) -> String = { $0 ?? "Claude Code's default" }
        if drawsFields {
            Picker("", selection: Binding(get: { selected }, set: { set($0) })) {
                ForEach(values, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } else {
            Text(label(selected))
                .font(.system(size: 13))
        }
    }
}

/// One option of the selected session's question: its key, then its label. ⌘ and the number, or
/// a click, chooses it; Return then sends.
struct PaletteOption: View {
    let index: Int
    let text: String
    let recommended: Bool
    let chosen: Bool
    let hover: HoverTracker
    let choose: (Int) -> Void

    private var id: String { "palette.answer.\(index)" }

    var body: some View {
        Button { choose(index) } label: {
            HStack(spacing: 6) {
                // Only the first nine have a key.
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(chosen ? .primary : .secondary)
                }
                Text(text)
                    .font(.system(size: 12.5, weight: chosen ? .semibold : .regular))
                    .lineLimit(1)
                if recommended {
                    Text("recommended")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(chosen ? Lamp.light.opacity(0.85) : Color.primary.opacity(hover.hovered == id ? 0.16 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(chosen ? Lamp.light : Color.primary.opacity(0.12), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.set(id, $0) }
    }
}

/// One existing session in the palette's list.
struct PaletteSessionRow: View {
    let row: InboxRow
    let isSelected: Bool
    let hover: HoverTracker
    /// The row is selected and its question can be answered here: it opens up to show the
    /// question in full and its options.
    var answers = false
    var chosen: Int?
    var choose: (Int) -> Void = { _ in }
    let open: () -> Void

    private var id: String { "palette.session.\(row.id)" }

    private func option(_ index: Int) -> PaletteOption {
        PaletteOption(index: index, text: row.options[index], recommended: index == row.recommendedOption, chosen: index == chosen, hover: hover, choose: choose)
    }

    private var lamp: Color {
        if row.isSnoozed || row.isQuiet { return Color.primary.opacity(0.25) }
        if row.kind.needsUser { return row.isOverdue ? Lamp.ember : Lamp.light }
        return Color.primary.opacity(0.14)
    }

    /// What the session wants, or what it is doing.
    var subtitle: String {
        switch row.kind {
        case .question, .approval, .waiting: row.detail ?? "Waiting for you"
        case .working: "Working"
        case .done: "Done"
        case .unknown: "State unknown"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(lamp)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                    if row.isPinned {
                        Image(systemName: row.isQuiet ? "pin.slash.fill" : "pin.fill")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Text(row.place)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(answers ? .primary : .secondary)
                    .lineLimit(answers ? 4 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                if answers {
                    // Side by side while they fit, one under another when the labels are long.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { ForEach(row.options.indices, id: \.self) { option($0) } }
                        VStack(alignment: .leading, spacing: 4) { ForEach(row.options.indices, id: \.self) { option($0) } }
                    }
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 8)
            if row.isRetryable {
                Text("Can be retried")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let age = row.age {
                Text(age)
                    .font(.system(size: 12))
                    .foregroundStyle(row.isOverdue && !row.isSnoozed ? Lamp.ember : .secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, answers ? 9 : 0)
        .frame(minHeight: 46)
        .background(
            RoundedRectangle(cornerRadius: PaletteSurface.radius - 12, style: .continuous)
                .fill(isSelected ? Lamp.light.opacity(0.24) : Color.primary.opacity(hover.hovered == id ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover.set(id, $0) }
        .padding(.horizontal, 6)
    }
}

/// One kept summary in the palette's notes: a line to pick it by; the summary itself is shown
/// below the list.
struct PaletteNoteRow: View {
    let note: SessionNote
    let reach: NoteReach
    let now: Date
    let isSelected: Bool
    let hover: HoverTracker
    let select: () -> Void

    private var id: String { "palette.note.\(note.id)" }

    static func age(_ note: SessionNote, now: Date) -> String {
        guard let age = Age.short(since: note.createdAt, now: now) else { return "" }
        return age == "just now" ? age : "\(age) ago"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: reach == .summaryOnly ? "note.text" : reach == .session ? "circle.fill" : "arrow.uturn.backward")
                .font(.system(size: reach == .session ? 6 : 10))
                .foregroundStyle(reach == .session ? Lamp.light : Color.secondary)
                .frame(width: 12)
            Text(note.name)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            Text(note.repo)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(reach.label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(Self.age(note, now: now))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: PaletteSurface.radius - 12, style: .continuous)
                .fill(isSelected ? Lamp.light.opacity(0.24) : Color.primary.opacity(hover.hovered == id ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hover.set(id, $0) }
        .padding(.horizontal, 6)
    }
}

/// One repository in the palette's list.
struct PaletteRepoRow: View {
    let repo: Repo
    let isSelected: Bool
    let home: String
    let hover: HoverTracker
    let choose: () -> Void
    let togglePin: () -> Void

    private var id: String { "palette.repo.\(repo.path)" }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(repo.hasSessions ? Lamp.light : Color.primary.opacity(0.14))
                .frame(width: 7, height: 7)
                .help(repo.hasSessions ? "Has sessions" : "No sessions here yet")
            Text(repo.name)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            Text(repo.displayPath(home: home))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 8)
            if repo.isPinned || hover.hovered == id {
                Button(action: togglePin) {
                    Image(systemName: repo.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(repo.isPinned ? Lamp.light : .secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(repo.isPinned ? "Unpin" : "Keep at the top")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: PaletteSurface.radius - 12, style: .continuous)
                .fill(isSelected ? Lamp.light.opacity(0.24) : Color.primary.opacity(hover.hovered == id ? 0.07 : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .onHover { hover.set(id, $0) }
        .padding(.horizontal, 6)
    }
}

/// A key and what it does, in the palette's bottom bar. Also a button, for the pointer.
struct KeyHint: View {
    let keys: String
    let label: String
    let id: String
    let hover: HoverTracker
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(keys)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.09)))
                Text(label)
                    .font(.system(size: 12, weight: prominent ? .medium : .regular))
            }
            .foregroundStyle(prominent || hover.hovered == id ? .primary : .secondary)
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(prominent ? Lamp.light.opacity(hover.hovered == id ? 0.42 : 0.30) : Color.primary.opacity(hover.hovered == id ? 0.09 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.set(id, $0) }
    }
}

/// The palette's card. In the live panel it is the system's glass, which is what a layer that
/// floats over other apps is made of on macOS 26 and later; before that, a blurred panel.
/// Offscreen, where neither can be drawn, it is the window colour.
struct PaletteSurface: ViewModifier {
    /// Large enough that rows and capsules inside sit concentric with the corners.
    static let radius: CGFloat = 22

    let glass: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    func body(content: Content) -> some View {
        if !glass {
            content
                .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                .clipShape(shape)
        } else if #available(macOS 26.0, *) {
            content
                .clipShape(shape)
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(BlurredBackdrop().clipShape(shape))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                .clipShape(shape)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
        }
    }
}

/// The blur behind the palette on systems without glass.
struct BlurredBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
