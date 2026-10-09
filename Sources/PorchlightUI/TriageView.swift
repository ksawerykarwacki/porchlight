import PorchlightCore
import SwiftUI

/// What the Triage tab shows, as plain values so it can be drawn without a model.
public struct TriageState {
    public var items: [TriageItem] = []
    public var isLoading = false
    public var hasLoaded = false
    public var isConfirmingBulk = false
    public var removing: String?
    public var summary: String?
    public var refusals: [TriageModel.Refusal] = []
    public var pendingWrapUp: String?
    public var summarising: String?
    public var notes: [String: SessionNote] = [:]
    public var wrapUpProblem: TriageModel.WrapUpProblem?
    public var summarisingEngine: WrapUpEngine?
    public var plan = WrapUpPlan()
    public var wrapUpModel: String { plan.model }

    public init() {}

    @MainActor
    public init(_ model: TriageModel) {
        items = model.items
        isLoading = model.isLoading
        hasLoaded = model.hasLoaded
        isConfirmingBulk = model.isConfirmingBulk
        removing = model.removing
        summary = model.summary
        refusals = model.refusals
        pendingWrapUp = model.pendingWrapUp
        summarising = model.summarising
        notes = model.notes
        wrapUpProblem = model.wrapUpProblem
        summarisingEngine = model.summarisingEngine
        plan = model.plan
    }

    var safe: [TriageItem] { items.filter { $0.verdict == .safeToRemove } }
}

/// The panel's Triage tab: idle sessions by verdict, and one button for the ones that can go.
struct TriagePage: View {
    let actions: InboxActions
    let hover: HoverTracker

    private var state: TriageState { actions.triage }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let summary = state.summary {
                ControlNote(
                    title: summary, text: state.refusals.map { "\($0.name): \($0.text)" }.joined(separator: "\n\n"), monospaced: !state.refusals.isEmpty,
                    primary: ("OK", actions.dismissTriageResult), secondary: nil, danger: nil, id: "triage.result", hover: hover)
                    .padding(.leading, -20)
                    .padding(.top, 4)
            }
            ForEach(TriageVerdict.allCases, id: \.self) { verdict in
                let group = state.items.filter { $0.verdict == verdict }
                if !group.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text(verdict.title)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(verdict.explanation)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(group.count)")
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                    ForEach(group) { item in
                        TriageRow(item: item, actions: actions, hover: hover, isBeingRemoved: state.removing == item.id, state: state)
                    }
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.headline(state))
                .font(.system(size: 12.5))
                .foregroundStyle(state.items.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if state.isConfirmingBulk {
                ControlNote(
                    title: nil,
                    text: "Remove these \(state.safe.count)? Each is removed the ordinary way, so Claude Code checks it again and refuses if anything would be lost.\n\n"
                        + state.safe.map(\.session.name).joined(separator: ", "),
                    monospaced: false, primary: ("Remove \(state.safe.count)", actions.confirmRemoveSafe), secondary: ("Cancel", actions.cancelRemoveSafe),
                    danger: nil, id: "triage.bulk", hover: hover)
                    .padding(.leading, -30)
                    .padding(.trailing, -10)
            } else if (!state.safe.isEmpty && state.removing == nil) || !state.notes.isEmpty {
                // Looking again is the footer's Refresh button.
                HStack(spacing: 2) {
                    if !state.safe.isEmpty, state.removing == nil {
                        QuietButton(
                            title: "Remove the \(state.safe.count) safe \(state.safe.count == 1 ? "one" : "ones")…", symbol: "trash", id: "triage.removeSafe", hover: hover,
                            action: actions.askRemoveSafe)
                    }
                    if !state.notes.isEmpty {
                        QuietButton(title: TriagePage.notesLink(state.notes.count), symbol: "note.text", id: "triage.notes", hover: hover, action: actions.showNotes)
                            .help("Read and search the summaries kept from wrapped-up sessions, also of sessions since removed")
                    }
                    Spacer()
                }
                .padding(.leading, -8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    static func notesLink(_ count: Int) -> String {
        "\(count) \(count == 1 ? "note" : "notes")"
    }

    static func headline(_ state: TriageState) -> String {
        if let removing = state.removing, let item = state.items.first(where: { $0.id == removing }) {
            return "Removing \(item.session.name)…"
        }
        if !state.hasLoaded { return "Looking at what each idle session holds…" }
        if state.items.isEmpty { return "Nothing to triage. Sessions appear here once they are finished, stopped, or have waited a long time." }
        let safe = state.safe.count
        let total = state.items.count
        let idle = "\(total) idle \(total == 1 ? "session" : "sessions")"
        return safe == 0 ? "\(idle); none can be removed without a decision." : "\(idle); \(safe) can be removed without losing anything."
    }
}

/// One idle session with its verdict's reasons and what can be done about it.
struct TriageRow: View {
    let item: TriageItem
    let actions: InboxActions
    let hover: HoverTracker
    let isBeingRemoved: Bool
    var state = TriageState()

    private var note: SessionNote? { state.notes[item.id] }
    private var id: String { "triage.\(item.id)" }
    private var isHovered: Bool { hover.hovered == id }

    private var lamp: Color {
        switch item.verdict {
        case .safeToRemove: Color.primary.opacity(0.18)
        case .needsDecision: Lamp.ember
        case .stale: Lamp.light
        case .keep: Color.primary.opacity(0.18)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(lamp)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.session.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(item.session.location.repoName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let age = Age.short(since: item.session.lastActivity, now: actions.triageNow) {
                            Text(age)
                                .font(.system(size: 11))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(item.reason)
                        .font(.system(size: 12))
                        .foregroundStyle(item.verdict == .needsDecision ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 2) {
                        QuietButton(title: "Open", symbol: nil, id: "\(id).open", hover: hover) { actions.open(item.id) }
                        QuietButton(title: "Remove…", symbol: nil, id: "\(id).remove", hover: hover) { actions.askControl(.remove, item.id) }
                        QuietButton(title: "Keep (pin)", symbol: nil, id: "\(id).pin", hover: hover) { actions.keepFromTriage(item.id) }
                            .help("Pin this session: it moves to Pinned on the Sessions tab and is no longer suggested for removal")
                        if state.summarising == nil {
                            QuietButton(title: note == nil ? "Wrap up…" : "Wrap up again…", symbol: nil, id: "\(id).wrap", hover: hover) { actions.askWrapUp(item.id) }
                                .help("Have a small model summarise what this session did and where it stopped, and keep the summary")
                        }
                    }
                    .padding(.leading, -8)
                    .opacity(isBeingRemoved ? 0.4 : 1)
                    if state.summarising == item.id {
                        Text(state.summarisingEngine == .onDevice ? "Summarising on this Mac…" : "Summarising with \(state.wrapUpModel)… a long conversation can take a minute.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if state.pendingWrapUp == item.id {
                ControlNote(
                    title: nil, text: TriageRow.wrapUpQuestion(state.plan), monospaced: false,
                    primary: ("Summarise", actions.confirmWrapUp), secondary: ("Cancel", actions.cancelWrapUp),
                    // Not a danger, but the third button's place: the thorough way, which costs.
                    danger: state.plan.engine == .onDevice ? (TriageRow.claudeInstead(state.plan), actions.confirmWrapUpWithClaude) : nil,
                    id: "triage.wrap.\(item.id)", hover: hover)
            } else if let problem = state.wrapUpProblem, problem.id == item.id {
                ControlNote(
                    title: "Not summarised", text: problem.text, monospaced: true,
                    primary: ("OK", actions.dismissWrapUpProblem), secondary: nil, danger: nil, id: "triage.wrapProblem.\(item.id)", hover: hover)
            }
            if let note, state.summarising != item.id {
                TriageNote(note: note, now: actions.triageNow, copy: { actions.copyResumeCommand(note) }, id: "\(id).note", hover: hover)
            }

            if let pending = actions.pendingControl, pending.sessionID == item.id {
                ControlNote(
                    title: pending.isForced ? "This cannot be undone" : nil, text: pending.question, monospaced: false,
                    primary: (pending.verb, actions.confirmControl), secondary: ("Cancel", actions.cancelControl), danger: nil,
                    id: "triage.control.\(item.id)", hover: hover)
            } else if let problem = actions.controlProblem, problem.sessionID == item.id {
                ControlNote(
                    title: problem.title, text: problem.text, monospaced: true,
                    primary: ("Open in terminal", { actions.open(item.id) }), secondary: ("Dismiss", actions.dismissControlProblem),
                    danger: problem.overrides.isEmpty ? nil : ("Discard and remove…", actions.askForcedRemoval),
                    id: "triage.problem.\(item.id)", hover: hover)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(isHovered ? 0.07 : 0)))
        .onHover { hover.set(id, $0) }
        .padding(.horizontal, 6)
    }

    /// The question for the engine in force. Whatever spends Claude usage says so.
    static func wrapUpQuestion(_ plan: WrapUpPlan) -> String {
        if plan.engine == .onDevice {
            return "Summarise this session on this Mac? Apple's on-device model reads the first request and the end of the conversation from Claude Code's files. "
                + "It is free and nothing leaves this Mac; the session is not changed. The summary is kept, also after the session is removed."
        }
        let question = wrapUpQuestion(model: plan.model)
        // The choice was this Mac and it cannot be honoured: say why before Claude is offered.
        if plan.chosen == .onDevice, let why = plan.onDevice.explanation { return "\(why)\n\n\(question)" }
        return question
    }

    static func claudeInstead(_ plan: WrapUpPlan) -> String {
        "Read all of it with \(plan.model) (uses Claude usage)"
    }

    static func wrapUpQuestion(model: String) -> String {
        "Summarise this session with \(model)? Claude Code reads the whole conversation as a copy, with every tool off, so the session itself is not changed. "
            + "It uses some of your Claude usage. The summary is kept, also after the session is removed."
    }
}

/// A session's kept summary, under its row.
struct TriageNote: View {
    let note: SessionNote
    let now: Date
    let copy: () -> Void
    let id: String
    let hover: HoverTracker

    static func caption(_ note: SessionNote, now: Date) -> String {
        let age = Age.short(since: note.createdAt, now: now).map { $0 == "just now" ? $0 : "\($0) ago" } ?? "just now"
        return "Summarised \(age) \(note.source). Kept after the session is removed."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.summary)
                .font(.system(size: 12))
                .lineLimit(14)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.caption(note, now: now))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            QuietButton(title: "Copy the command to resume it", symbol: "doc.on.doc", id: "\(id).copy", hover: hover, action: copy)
                .padding(.leading, -8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.leading, 30)
        .padding(.trailing, 10)
        .padding(.bottom, 6)
    }
}
