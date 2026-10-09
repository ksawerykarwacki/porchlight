import PorchlightCore
import PorchlightMac
import SwiftUI

/// What the inbox's buttons do. Plain closures, so the view can be rendered without a model.
public struct InboxActions {
    public var open: (String) -> Void = { _ in }
    public var copyReply: (String) -> Void = { _ in }
    public var snooze: (String, SnoozeChoice) -> Void = { _, _ in }
    public var openAgentView: () -> Void = {}
    /// Opens the palette that starts a new session.
    public var newSession: () -> Void = {}
    /// The sessions the user keeps on purpose.
    public var pins = Pins()
    public var togglePin: (String) -> Void = { _ in }
    public var setPinQuiet: (String, Bool) -> Void = { _, _ in }
    /// What is left to set up, for the first-run card.
    public var setupSteps: [SetupStep] = []
    public var performSetup: (SetupStep.Kind) -> Void = { _ in }
    public var hideSetup: () -> Void = {}
    /// A stop or removal waiting to be confirmed, and the last one that was refused.
    public var pendingControl: PendingControl?
    public var controlProblem: ControlProblem?
    public var askControl: (SessionAction, String) -> Void = { _, _ in }
    public var cancelControl: () -> Void = {}
    public var confirmControl: () -> Void = {}
    public var dismissControlProblem: () -> Void = {}
    /// After a refused removal that named what would be lost: ask again, to remove anyway.
    public var askForcedRemoval: () -> Void = {}
    /// A worktree a removal left on disk.
    public var leftover: String?
    public var dismissLeftover: () -> Void = {}
    /// The general settings: opening at login (nil when this copy cannot), the folders searched
    /// for repositories, and why reminders are not delivered.
    public var launchesAtLogin: Bool?
    public var setLaunchesAtLogin: (Bool) -> Void = { _ in }
    public var workspaceRoots: [String] = []
    public var removeWorkspaceRoot: (String) -> Void = { _ in }
    public var notificationProblem: String?
    /// Updates of a Homebrew install: one line of status (nil hides the section), whether there
    /// is something to install, and whether a check or an update is running.
    public var updateSummary: String?
    public var canUpdate = false
    public var updateIsBusy = false
    /// True when Homebrew installed this copy; opening at login is then Homebrew's to arrange.
    public var installedWithHomebrew = false
    public var checkForUpdate: () -> Void = {}
    public var installUpdate: () -> Void = {}
    /// The shortcut that opens the new-session palette from any app.
    public var hotkey: Hotkey?
    public var setHotkey: (Hotkey?) -> Void = { _ in }
    public var refresh: () -> Void = {}
    public var quit: () -> Void = {}
    /// Terminals the user can pick, as (identifier, name). Empty hides the chooser.
    public var terminals: [(id: String, name: String)] = []
    /// The picked terminal's identifier, or nil for "whichever is running".
    public var chosenTerminal: String?
    public var chooseTerminal: (String?) -> Void = { _ in }
    /// The name of the terminal "whichever is running" would use right now.
    public var automaticTerminalName: String?
    public var prefersAgentView = false
    public var setPrefersAgentView: (Bool) -> Void = { _ in }
    /// Whether the panel shows the reminder settings instead of the sessions.
    public var showsSettings = false
    /// Whether the panel shows the Triage tab. Never true together with `showsSettings`.
    public var showsTriage = false
    public var setShowsTriage: (Bool) -> Void = { _ in }
    public var triage = TriageState()
    /// The clock the Triage tab's ages are measured against.
    public var triageNow = Date()
    public var reloadTriage: () -> Void = {}
    public var askRemoveSafe: () -> Void = {}
    public var cancelRemoveSafe: () -> Void = {}
    public var confirmRemoveSafe: () -> Void = {}
    public var dismissTriageResult: () -> Void = {}
    /// Pins a session from its Triage row and takes the row away.
    public var keepFromTriage: (String) -> Void = { _ in }
    public var setShowsSettings: (Bool) -> Void = { _ in }
    public var reminders = ReminderSettings()
    public var updateReminders: ((inout ReminderSettings) -> Void) -> Void = { _ in }
    /// Opens a session that stopped on a passing failure, with a line to resend on the clipboard.
    public var retry: (String) -> Void = { _ in }
    /// The patterns that decide which rows offer Retry.
    public var transientErrors = TransientErrors()

    public init() {}
}

/// Which row or button the pointer is over. An observable object rather than view state, because
/// `@State` is not available without Xcode (see PorchlightApp).
@MainActor
@Observable
public final class HoverTracker {
    public var hovered: String?

    public init(hovered: String? = nil) {
        self.hovered = hovered
    }

    func set(_ id: String, _ inside: Bool) {
        if inside {
            hovered = id
        } else if hovered == id {
            hovered = nil
        }
    }
}

/// The two colours Porchlight owns: the lamp that is on for you, and the same lamp left too long.
/// Everything else in the panel uses the system's own colours.
enum Lamp {
    static let light = Color(red: 1.0, green: 0.70, blue: 0.16)
    static let ember = Color(red: 0.98, green: 0.20, blue: 0.26)
}

/// The dropdown under the menu-bar icon.
public struct InboxView: View {
    let snapshot: StoreSnapshot
    let now: Date
    let notice: String?
    /// Shown above the buttons while reminders cannot be delivered.
    let notificationProblem: String?
    let snoozes: [String: Snooze]
    let actions: InboxActions
    let hover: HoverTracker
    /// Off for offscreen rendering, which cannot draw a scroll view.
    let scrolls: Bool

    public init(
        snapshot: StoreSnapshot, now: Date = Date(), notice: String? = nil, notificationProblem: String? = nil,
        snoozes: [String: Snooze] = [:], actions: InboxActions = InboxActions(), hover: HoverTracker? = nil, scrolls: Bool = true
    ) {
        self.snoozes = snoozes
        self.snapshot = snapshot
        self.now = now
        self.notice = notice
        self.notificationProblem = notificationProblem
        self.actions = actions
        self.hover = hover ?? HoverTracker()
        self.scrolls = scrolls
    }

    public init(
        model: InboxModel, updates: UpdateModel? = nil, triage: TriageModel? = nil, newSession: @escaping () -> Void = {},
        quit: @escaping () -> Void
    ) {
        var actions = InboxActions()
        actions.showsTriage = model.showsTriage
        actions.triageNow = model.now
        if let triage {
            actions.triage = TriageState(triage)
            actions.setShowsTriage = { shows in
                model.showsTriage = shows
                if shows {
                    model.showsSettings = false
                    // Looked at afresh each time the tab is opened: it reads the disk and asks gh.
                    Task { await triage.load() }
                }
            }
            actions.reloadTriage = { Task { await triage.load() } }
            actions.askRemoveSafe = { triage.askRemoveSafe() }
            actions.cancelRemoveSafe = { triage.cancelRemoveSafe() }
            actions.confirmRemoveSafe = { Task { await triage.confirmRemoveSafe() } }
            actions.dismissTriageResult = { triage.dismissResult() }
            actions.keepFromTriage = { id in
                model.keep(sessionID: id)
                triage.exclude(id)
            }
        }
        if let updates {
            actions.updateSummary = updates.summary
            actions.canUpdate = updates.canUpdate
            actions.updateIsBusy = [.checking, .updating, .restarting].contains(updates.state)
            actions.installedWithHomebrew = updates.installed != nil
            actions.checkForUpdate = { Task { await updates.check() } }
            actions.installUpdate = { Task { await updates.update() } }
        }
        actions.newSession = newSession
        actions.pins = model.pins
        actions.togglePin = { model.togglePin(sessionID: $0) }
        actions.setPinQuiet = { id, quiet in model.setPinQuiet(sessionID: id, quiet) }
        actions.setupSteps = model.setupSteps
        actions.performSetup = { kind in Task { await model.performSetup(kind) } }
        actions.hideSetup = { model.hideSetup() }
        actions.pendingControl = model.pendingControl
        actions.controlProblem = model.controlProblem
        actions.askControl = { action, id in model.askControl(action, sessionID: id) }
        actions.cancelControl = { model.cancelControl() }
        actions.confirmControl = { Task { await model.confirmControl() } }
        actions.dismissControlProblem = { model.dismissControlProblem() }
        actions.askForcedRemoval = { model.askForcedRemoval() }
        actions.leftover = model.leftover
        actions.dismissLeftover = { model.dismissLeftover() }
        actions.launchesAtLogin = model.setupFacts.launchesAtLogin
        actions.setLaunchesAtLogin = { value in Task { await model.setLaunchesAtLogin(value) } }
        actions.workspaceRoots = model.workspaceRoots
        actions.removeWorkspaceRoot = { root in Task { await model.removeWorkspaceRoot(root) } }
        actions.notificationProblem = model.notificationProblem
        actions.hotkey = model.hotkey
        actions.setHotkey = { model.setHotkey($0) }
        actions.open = { model.open(sessionID: $0) }
        actions.copyReply = { model.copyReply(sessionID: $0) }
        actions.snooze = { id, choice in Task { await model.snooze(sessionID: id, choice) } }
        actions.openAgentView = { model.openAgentView() }
        actions.refresh = { model.refresh() }
        actions.quit = quit
        actions.terminals = model.installedTerminals.map { (id: $0.rawValue, name: $0.displayName) }
        actions.chosenTerminal = model.chosenTerminal?.rawValue
        actions.chooseTerminal = { id in model.chooseTerminal(id.flatMap { TerminalApp(rawValue: $0) }) }
        actions.automaticTerminalName = model.automaticTerminal?.displayName
        actions.prefersAgentView = model.prefersAgentView
        actions.setPrefersAgentView = { model.setPrefersAgentView($0) }
        actions.showsSettings = model.showsSettings
        actions.setShowsSettings = { shows in
            model.showsSettings = shows
            if shows { model.showsTriage = false }
        }
        actions.reminders = model.reminderSettings
        actions.updateReminders = { model.updateReminders($0) }
        actions.retry = { model.retry(sessionID: $0) }
        actions.transientErrors = model.transientErrors
        self.init(
            snapshot: model.snapshot, now: model.now, notice: model.notice, notificationProblem: model.notificationProblem,
            snoozes: model.snoozes, actions: actions, hover: model.hover)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                TabButton(title: "Sessions", selected: !actions.showsSettings && !actions.showsTriage, id: "tab.sessions", hover: hover) {
                    actions.setShowsSettings(false)
                    actions.setShowsTriage(false)
                }
                TabButton(title: "Triage", selected: actions.showsTriage, id: "tab.triage", hover: hover) {
                    actions.setShowsTriage(true)
                }
                TabButton(title: "Settings", selected: actions.showsSettings, id: "tab.settings", hover: hover) {
                    actions.setShowsSettings(true)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 6)
            Divider()

            if let stale = snapshot.staleNotice(now: now) {
                Label(stale, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Lamp.ember)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
            }

            if scrolls {
                // Every tab is laid out and only one is shown, so the panel is as tall as the
                // tallest of them and switching tabs never resizes its window. A window that
                // gets shorter keeps its bottom edge, which would drop it away from the menu bar.
                ZStack(alignment: .top) {
                    // Shorter than the session list's limit: the settings scroll, so that a few
                    // sessions do not sit in a panel as tall as the whole settings page.
                    ScrollView { SettingsPage(actions: actions) }
                        .frame(maxHeight: 360)
                        .fixedSize(horizontal: false, vertical: true)
                        .shown(actions.showsSettings)
                    ScrollView { sessionList }
                        .frame(maxHeight: 480)
                        // The menu-bar window sizes its content to the minimum it will accept, and
                        // a scroll view accepts almost nothing. Fixing it at its ideal height (the
                        // list's height, up to the limit above) is what keeps the rows visible.
                        .fixedSize(horizontal: false, vertical: true)
                        .shown(!actions.showsSettings && !actions.showsTriage)
                    ScrollView { TriagePage(actions: actions, hover: hover) }
                        .frame(maxHeight: 480)
                        .fixedSize(horizontal: false, vertical: true)
                        .shown(actions.showsTriage)
                }
            } else if actions.showsTriage {
                TriagePage(actions: actions, hover: hover)
            } else if actions.showsSettings {
                SettingsPage(actions: actions, drawsMenus: false)
            } else {
                sessionList
            }

            Divider()
            footer
        }
        .frame(width: 400)
    }

    @ViewBuilder private var sessionList: some View {
        if !actions.setupSteps.isEmpty {
            SetupCard(steps: actions.setupSteps, hover: hover, perform: actions.performSetup, hide: actions.hideSetup)
        }
        if let leftover = actions.leftover {
            ControlNote(
                title: "A worktree was left on disk", text: leftover, monospaced: false,
                primary: ("OK", actions.dismissLeftover), secondary: nil, danger: nil, id: "leftover", hover: hover)
                .padding(.leading, -20)
                .padding(.top, 8)
        }
        let sections = InboxGroups(sessions: snapshot.sessions, now: now)
            .sections(
                now: now, snoozes: snoozes, overdueAfter: actions.reminders.secondStep, transientErrors: actions.transientErrors,
                pins: actions.pins, pinned: snapshot.sessions)
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.fetchedAt == nil && !snapshot.isStale ? "Looking for sessions…" : "No background sessions")
                        .font(.system(size: 13, weight: .medium))
                    if snapshot.fetchedAt != nil {
                        Text("Start one with claude --bg and it will show up here.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            ForEach(Array(sections.enumerated()), id: \.element.title) { index, section in
                HStack(alignment: .firstTextBaseline) {
                    Text(section.title)
                    Spacer()
                    Text("\(section.rows.count)")
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, index == 0 ? 12 : 14)
                .padding(.bottom, 4)

                ForEach(section.rows) { row in
                    InboxRowView(row: row, actions: actions, hover: hover, drawsMenus: scrolls)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notificationProblem {
                Label(notificationProblem, systemImage: "bell.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }
            if let notice {
                Text(notice)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
            HStack(spacing: 2) {
                QuietButton(title: "New session", symbol: "plus", id: "footer.new", hover: hover, action: actions.newSession)
                QuietButton(title: "Agent view", symbol: "rectangle.stack", id: "footer.agents", hover: hover, action: actions.openAgentView)
                QuietButton(title: "Refresh", symbol: "arrow.clockwise", id: "footer.refresh", hover: hover, action: actions.refresh)
                Spacer()
                QuietButton(title: "Quit", symbol: nil, id: "footer.quit", hover: hover, action: actions.quit)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

extension InboxActions {
    /// What "whichever is running" means right now, so the choice is not a guess.
    var automaticTerminalTitle: String {
        automaticTerminalName.map { "Whichever is running (now \($0))" } ?? "Whichever is running"
    }

    func terminalTitle(_ id: String?) -> String {
        guard let id else { return automaticTerminalTitle }
        return terminals.first { $0.id == id }?.name ?? id
    }
}

/// One of the panel's two tabs.
private extension View {
    /// Keeps the view's place in the layout while hiding it from the eye, the pointer and VoiceOver.
    func shown(_ visible: Bool) -> some View {
        opacity(visible ? 1 : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }
}

struct TabButton: View {
    let title: String
    let selected: Bool
    let id: String
    let hover: HoverTracker
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected || hover.hovered == id ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(selected ? 0.10 : (hover.hovered == id ? 0.06 : 0))))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.set(id, $0) }
        .animation(.easeOut(duration: 0.12), value: hover.hovered == id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One session. The whole row opens it; a session with a suggested reply also offers to copy it.
struct InboxRowView: View {
    let row: InboxRow
    let actions: InboxActions
    let hover: HoverTracker
    /// Off for offscreen rendering, which draws a system menu as a placeholder block.
    var drawsMenus = true

    private var isHovered: Bool { hover.hovered == row.id }

    /// The moon on the title line. The words are in its tooltip and, for a snoozed row, in the
    /// age next to it; a label here used to sit on top of the question.
    private var snoozeLabel: some View {
        Image(systemName: row.isSnoozed ? "moon.zzz.fill" : "moon")
            .font(.system(size: 12, weight: .medium))
    }
    /// Room kept at the end of the title line for the row's controls, so they never cover text.
    private var controlsWidth: CGFloat {
        // The menu is on every row: any session can be pinned.
        (waits ? 22 : 0) + 22
    }
    private var waits: Bool { row.kind == .question || row.kind == .approval || row.kind == .waiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                actions.open(row.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    StatusLamp(kind: row.kind, overdue: row.isOverdue, snoozed: row.isSnoozed)
                        .frame(width: 10, height: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.title)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            if row.isPinned {
                                Image(systemName: row.isQuiet ? "pin.slash.fill" : "pin.fill")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(.secondary)
                                    .help(row.isQuiet ? "Pinned, with reminders off" : "Pinned")
                            }
                            Spacer(minLength: 8)
                            if let age = row.age {
                                Text(age)
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(row.isOverdue && !row.isSnoozed ? AnyShapeStyle(Lamp.ember) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            // The row's own controls are drawn over this gap.
                            Color.clear.frame(width: controlsWidth, height: 1)
                        }
                        HStack(spacing: 4) {
                            Text(row.repo)
                            if let worktree = row.worktree {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 9))
                                Text(worktree)
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                        if let detail = row.detail {
                            Text(row.kind == .approval ? "\(row.tool ?? "Tool"): \(detail)" : detail)
                                .font(row.kind == .approval ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5))
                                .foregroundStyle(waits ? .primary : .secondary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 3)
                        }
                        if !row.options.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(row.options.enumerated()), id: \.offset) { index, option in
                                    OptionChip(text: option, recommended: index == row.recommendedOption)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 7)
                .padding(.bottom, row.suggestedReply == nil ? 7 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in your terminal")
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 8) {
                    if waits {
                        // Shown for the row under the pointer, and always for a snoozed one, so
                        // a snooze can be seen and undone.
                        Group {
                            if drawsMenus {
                                Menu {
                                    ForEach(row.snoozeChoices, id: \.self) { choice in
                                        Button(choice.title) { actions.snooze(row.id, choice) }
                                    }
                                } label: {
                                    snoozeLabel
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            } else {
                                snoozeLabel
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .opacity(isHovered || row.isSnoozed ? 1 : 0)
                        .help(row.isSnoozed ? "Reminders are paused for this session" : "Pause reminders for this session")
                    }
                    do {
                        // Stop and remove ask before they do anything, so they sit one click away.
                        Group {
                            if drawsMenus {
                                Menu {
                                    Button(row.isPinned ? "Unpin" : "Pin") { actions.togglePin(row.id) }
                                    if row.isPinned {
                                        Button(row.isQuiet ? "Turn its reminders back on" : "Turn its reminders off") {
                                            actions.setPinQuiet(row.id, !row.isQuiet)
                                        }
                                    }
                                    if row.canStop || row.canRemove { Divider() }
                                    if row.canStop {
                                        Button("Stop…") { actions.askControl(.stop, row.id) }
                                    }
                                    if row.canRemove {
                                        Button("Remove…") { actions.askControl(.remove, row.id) }
                                    }
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                            } else {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .opacity(isHovered ? 1 : 0)
                        .help(row.isPinned ? "Unpin, or stop this session" : "Pin, stop or remove this session")
                    }
                }
                .padding(.trailing, 10)
                .padding(.top, 7)
            }

            if row.suggestedReply != nil {
                Button {
                    actions.copyReply(row.id)
                } label: {
                    Label("Copy suggested reply", systemImage: "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(hover.hovered == "reply.\(row.id)" ? 0.16 : 0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .onHover { hover.set("reply.\(row.id)", $0) }
                .padding(.leading, 30)
                .padding(.bottom, 8)
            }

            if row.isRetryable {
                // Said in words as well as offered: the session is not asking anything, it
                // stopped on a failure that has probably passed.
                HStack(spacing: 8) {
                    Button {
                        actions.retry(row.id)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.primary.opacity(hover.hovered == "retry.\(row.id)" ? 0.16 : 0.08)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { hover.set("retry.\(row.id)", $0) }
                    .help("Open the session with \u{201C}\(actions.transientErrors.resend)\u{201D} on the clipboard, ready to send")
                    Text("Can be retried")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 30)
                .padding(.bottom, 8)
            }

            if let pending = actions.pendingControl, pending.sessionID == row.id {
                ControlNote(
                    title: pending.isForced ? "This cannot be undone" : nil, text: pending.question, monospaced: false,
                    primary: (pending.verb, actions.confirmControl), secondary: ("Cancel", actions.cancelControl), danger: nil,
                    id: "control.\(row.id)", hover: hover)
            } else if let problem = actions.controlProblem, problem.sessionID == row.id {
                // Claude Code's own words: for a removal they say what would be lost.
                ControlNote(
                    title: problem.title, text: problem.text, monospaced: true,
                    primary: ("Open in terminal", { actions.open(row.id) }), secondary: ("Dismiss", actions.dismissControlProblem),
                    // Only when Claude Code itself named what to pass; it asks once more first.
                    danger: problem.overrides.isEmpty ? nil : ("Discard and remove…", actions.askForcedRemoval),
                    id: "problem.\(row.id)", hover: hover)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.07 : 0))
        )
        .onHover { hover.set(row.id, $0) }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .padding(.horizontal, 6)
    }
}

/// The small lamp at the start of a row: lit for a waiting session, red once it has waited long,
/// a ring while the session works, a tick when it is finished.
struct StatusLamp: View {
    let kind: InboxRow.Kind
    let overdue: Bool
    var snoozed = false

    var body: some View {
        switch kind {
        case .question, .approval, .waiting:
            if snoozed {
                // Still waiting, but the user said "not now": the lamp is turned down.
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            } else {
                lit
            }
        case .working:
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1.5)
                .frame(width: 8, height: 8)
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
        case .unknown:
            Circle()
                .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                .frame(width: 8, height: 8)
        }
    }

    private var lit: some View {
        let colour = overdue ? Lamp.ember : Lamp.light
        return Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
            .shadow(color: colour.opacity(0.75), radius: 3.5)
    }
}

/// One of the choices a session offered. The one Claude recommends is lit.
struct OptionChip: View {
    let text: String
    let recommended: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(text)
                .lineLimit(1)
            if recommended {
                Text("recommended")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(recommended ? Lamp.light.opacity(0.22) : Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(recommended ? Lamp.light.opacity(0.55) : Color.primary.opacity(0.10), lineWidth: 1))
    }
}

/// What is left to set up, at the top of the sessions: problems that stop Porchlight working,
/// and optional steps that can be done here or hidden.
struct SetupCard: View {
    let steps: [SetupStep]
    let hover: HoverTracker
    let perform: (SetupStep.Kind) -> Void
    let hide: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(step.isProblem ? Lamp.ember : Lamp.light)
                        .frame(width: 8, height: 8)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.title)
                            .font(.system(size: 12.5, weight: .semibold))
                        Text(step.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if let action = step.action {
                            Button {
                                perform(step.kind)
                            } label: {
                                Text(action)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color.primary.opacity(hover.hovered == "setup.\(step.id)" ? 0.16 : 0.08)))
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .onHover { hover.set("setup.\(step.id)", $0) }
                            .padding(.top, 2)
                        }
                    }
                }
            }
            if Setup.canHide(steps) {
                HStack {
                    Text("These stay available on the Settings tab.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    QuietButton(title: "Hide these", symbol: nil, id: "setup.hide", hover: hover, action: hide)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

/// A question or a refusal shown inside a row, with the two things that can be done about it.
struct ControlNote: View {
    let title: String?
    let text: String
    let monospaced: Bool
    let primary: (title: String, action: () -> Void)
    let secondary: (title: String, action: () -> Void)?
    /// A third button for something that destroys work; it leads to a second question.
    let danger: (title: String, action: () -> Void)?
    let id: String
    let hover: HoverTracker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(text)
                .font(monospaced ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .foregroundStyle(monospaced ? .secondary : .primary)
                // Long enough for Claude Code's whole refusal: what it says would be lost is the
                // part that must not be cut off.
                .lineLimit(18)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                button(primary.title, id: "\(id).primary", strong: true, action: primary.action)
                if let secondary {
                    button(secondary.title, id: "\(id).secondary", strong: false, action: secondary.action)
                }
            }
            if let danger {
                // On a line of its own: beside the other two its title wrapped.
                button(danger.title, id: "\(id).danger", strong: false, action: danger.action)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        .padding(.leading, 30)
        .padding(.trailing, 10)
        .padding(.bottom, 8)
    }

    private func button(_ title: String, id: String, strong: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: strong ? .semibold : .medium))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(strong ? Lamp.ember.opacity(hover.hovered == id ? 0.30 : 0.20) : Color.primary.opacity(hover.hovered == id ? 0.16 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.set(id, $0) }
    }
}

/// A footer button that stays out of the way until the pointer is over it.
struct QuietButton: View {
    let title: String
    let symbol: String?
    let id: String
    let hover: HoverTracker
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
            }
            .font(.system(size: 12))
            .foregroundStyle(hover.hovered == id ? .primary : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hover.hovered == id ? 0.09 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover.set(id, $0) }
        .animation(.easeOut(duration: 0.12), value: hover.hovered == id)
    }
}

/// The panel's Settings tab: when Porchlight reminds, and where sessions open.
struct SettingsPage: View {
    let actions: InboxActions
    /// Off for offscreen rendering, which draws system pickers as placeholder blocks.
    var drawsMenus = true
    /// Whether macOS lets this copy of the app send time-sensitive notifications.
    var timeSensitive = TimeSensitiveSupport.current

    private var settings: ReminderSettings { actions.reminders }
    private var update: ((inout ReminderSettings) -> Void) -> Void { actions.updateReminders }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Reminders")
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 2)
            Text("For a session that keeps waiting on you.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)

            row("First reminder after") {
                choice(ReminderOptions.firstSteps, selected: settings.firstStep, label: ReminderOptions.duration) { value in
                    update { $0.setSteps(first: value, second: $0.secondStep) }
                }
            }
            row("Again, with sound, after") {
                choice(ReminderOptions.secondSteps.filter { $0 > settings.firstStep }, selected: settings.secondStep, label: ReminderOptions.duration) { value in
                    update { $0.setSteps(first: $0.firstStep, second: value) }
                }
            }
            row("Then repeat every") {
                choice(ReminderOptions.repeats, selected: settings.repeatEvery, label: { $0.map(ReminderOptions.duration) ?? "Never" }) { value in
                    update { $0.repeatEvery = value }
                }
            }
            row("Mark as time-sensitive after") {
                choice(ReminderOptions.timeSensitiveAfter, selected: settings.timeSensitiveAfter, label: { $0.map(ReminderOptions.duration) ?? "Off" }) { value in
                    update { $0.timeSensitiveAfter = value }
                }
            }
            // Said under the row rather than by hiding it: the choice is kept and starts to
            // work once macOS allows the level.
            if settings.timeSensitiveAfter != nil, let note = timeSensitive.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
            }

            Divider().padding(.vertical, 10)

            row("Daily summary at") {
                choice(ReminderOptions.digestHours, selected: settings.digestMinute.map { $0 / 60 }, label: { $0.map(ReminderOptions.hour) ?? "Off" }) { value in
                    update { $0.digestMinute = value.map { $0 * 60 } }
                }
            }
            row("Quiet hours") {
                HStack(spacing: 6) {
                    choice([false, true], selected: settings.quietHours != nil, label: { $0 ? "On" : "Off" }) { on in
                        update { $0.quietHours = on ? QuietHours(startMinute: 22 * 60, endMinute: 7 * 60) : nil }
                    }
                    if let quiet = settings.quietHours {
                        choice(Array(0..<24), selected: quiet.startMinute / 60, label: ReminderOptions.hour) { hour in
                            update { $0.quietHours?.startMinute = hour * 60 }
                        }
                        Text("to").foregroundStyle(.secondary)
                        choice(Array(0..<24), selected: quiet.endMinute / 60, label: ReminderOptions.hour) { hour in
                            update { $0.quietHours?.endMinute = hour * 60 }
                        }
                    }
                }
            }
            row("Question text in notifications") {
                choice([false, true], selected: settings.hideDetails, label: { $0 ? "Hidden" : "Shown" }) { value in
                    update { $0.hideDetails = value }
                }
            }

            if !actions.terminals.isEmpty {
                Divider().padding(.vertical, 10)

                Text("Opening sessions")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.bottom, 2)
                Text("Where a session goes when you click it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)

                row("Terminal") {
                    choice([nil] + actions.terminals.map { Optional($0.id) }, selected: actions.chosenTerminal, label: actions.terminalTitle) { id in
                        actions.chooseTerminal(id)
                    }
                }
                row("When agent view is already open") {
                    choice([false, true], selected: actions.prefersAgentView, label: { $0 ? "Switch to it" : "Open a new tab" }) { value in
                        actions.setPrefersAgentView(value)
                    }
                }
            }

            Divider().padding(.vertical, 10)
            row("Shortcut for a new session") {
                if drawsMenus {
                    if actions.hotkey != nil {
                        Button("Remove") { actions.setHotkey(nil) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    } else {
                        // One click instead of recording. Nothing is registered until it is clicked.
                        Button("Use \(Hotkey.suggested.display)") { actions.setHotkey(.suggested) }
                            .buttonStyle(.link)
                            .font(.system(size: 12))
                    }
                    HotkeyRecorder(hotkey: actions.hotkey, onChange: actions.setHotkey)
                        .fixedSize()
                } else {
                    // Offscreen, an AppKit button is drawn as its title.
                    Text(HotkeyRecorder.RecorderButton.title(for: actions.hotkey, recording: false))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().padding(.vertical, 10)
            Text("General")
                .font(.system(size: 13, weight: .semibold))
                .padding(.bottom, 6)
            if let launches = actions.launchesAtLogin {
                row("Open Porchlight at login") {
                    if drawsMenus {
                        Toggle("", isOn: Binding(get: { launches }, set: { actions.setLaunchesAtLogin($0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    } else {
                        Text(launches ? "On" : "Off").foregroundStyle(.secondary)
                    }
                }
            }
            if actions.installedWithHomebrew {
                // Two ways to start at login would start two copies; Homebrew's is the one.
                Text("To open Porchlight at login, run: brew services start porchlight")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            row("Folders searched for repositories") {
                Button("Add a folder…") { actions.performSetup(.workspace) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            if actions.workspaceRoots.isEmpty {
                Text("None yet. Folders of sessions you already have are listed anyway.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(actions.workspaceRoots, id: \.self) { root in
                HStack(spacing: 6) {
                    Text(root)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Remove") { actions.removeWorkspaceRoot(root) }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                }
                .padding(.vertical, 2)
            }
            if let summary = actions.updateSummary {
                Divider().padding(.vertical, 10)
                Text("Updates")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.bottom, 2)
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if actions.installedWithHomebrew, !actions.updateIsBusy {
                    HStack(spacing: 14) {
                        if actions.canUpdate {
                            Button("Update and restart") { actions.installUpdate() }
                                .buttonStyle(.link)
                        }
                        Button("Check now") { actions.checkForUpdate() }
                            .buttonStyle(.link)
                    }
                    .font(.system(size: 12))
                    .padding(.top, 4)
                }
            }
            if let problem = actions.notificationProblem {
                Divider().padding(.vertical, 10)
                Text("Reminders cannot reach you")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.bottom, 2)
                Text(problem)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Notification settings") { actions.performSetup(.notifications) }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .padding(.top, 4)
            }
        }
        .font(.system(size: 12.5))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 4)
    }

    /// A pop-up of choices. Offscreen it is drawn as its current value, since a system picker
    /// cannot be rendered there.
    @ViewBuilder
    private func choice<Value: Hashable>(_ values: [Value], selected: Value, label: @escaping (Value) -> String, set: @escaping (Value) -> Void) -> some View {
        if drawsMenus {
            Picker("", selection: Binding(get: { selected }, set: { set($0) })) {
                // A value saved by hand that is not one of the choices still shows, as itself.
                ForEach(values.contains(selected) ? values : [selected] + values, id: \.self) { value in
                    Text(label(value)).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        } else {
            Text(label(selected))
                .foregroundStyle(.secondary)
        }
    }
}
