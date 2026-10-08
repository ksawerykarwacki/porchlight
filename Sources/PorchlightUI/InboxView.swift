import PorchlightCore
import PorchlightMac
import SwiftUI

/// What the inbox's buttons do. Plain closures, so the view can be rendered without a model.
public struct InboxActions {
    public var open: (String) -> Void = { _ in }
    public var copyReply: (String) -> Void = { _ in }
    public var snooze: (String, SnoozeChoice) -> Void = { _, _ in }
    public var openAgentView: () -> Void = {}
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
    public var setShowsSettings: (Bool) -> Void = { _ in }
    public var reminders = ReminderSettings()
    public var updateReminders: ((inout ReminderSettings) -> Void) -> Void = { _ in }

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

    public init(model: InboxModel, quit: @escaping () -> Void) {
        var actions = InboxActions()
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
        actions.setShowsSettings = { model.showsSettings = $0 }
        actions.reminders = model.reminderSettings
        actions.updateReminders = { model.updateReminders($0) }
        self.init(
            snapshot: model.snapshot, now: model.now, notice: model.notice, notificationProblem: model.notificationProblem,
            snoozes: model.snoozes, actions: actions, hover: model.hover)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                TabButton(title: "Sessions", selected: !actions.showsSettings, id: "tab.sessions", hover: hover) {
                    actions.setShowsSettings(false)
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
                // Both tabs are laid out and only one is shown, so the panel is as tall as the
                // taller of the two and switching tabs never resizes its window. A window that
                // gets shorter keeps its bottom edge, which would drop it away from the menu bar.
                ZStack(alignment: .top) {
                    SettingsPage(actions: actions)
                        .shown(actions.showsSettings)
                    ScrollView { sessionList }
                        .frame(maxHeight: 480)
                        // The menu-bar window sizes its content to the minimum it will accept, and
                        // a scroll view accepts almost nothing. Fixing it at its ideal height (the
                        // list's height, up to the limit above) is what keeps the rows visible.
                        .fixedSize(horizontal: false, vertical: true)
                        .shown(!actions.showsSettings)
                }
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
        let sections = InboxGroups(sessions: snapshot.sessions, now: now)
            .sections(now: now, snoozes: snoozes, overdueAfter: actions.reminders.secondStep)
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

    private var snoozeLabel: some View {
        Label(row.isSnoozed ? "Snoozed" : "Snooze", systemImage: row.isSnoozed ? "moon.zzz.fill" : "moon")
            .font(.system(size: 11.5, weight: .medium))
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
                            Spacer(minLength: 8)
                            if let age = row.age {
                                Text(age)
                                    .font(.system(size: 11))
                                    .monospacedDigit()
                                    .foregroundStyle(row.isOverdue && !row.isSnoozed ? AnyShapeStyle(Lamp.ember) : AnyShapeStyle(.secondary))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            // Appears under the pointer: says the row is a button and what it does.
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .opacity(isHovered ? 1 : 0)
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
            .overlay(alignment: .bottomTrailing) {
                if waits {
                    // Shown for the row under the pointer, and always for a snoozed one, so a
                    // snooze can be seen and undone.
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
                    .padding(.trailing, 10)
                    .padding(.bottom, 6)
                    .opacity(isHovered || row.isSnoozed ? 1 : 0)
                    .help(row.isSnoozed ? "Reminders are paused for this session" : "Pause reminders for this session")
                }
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
