import PorchlightCore
import PorchlightMac
import SwiftUI

/// What the inbox's buttons do. Plain closures, so the view can be rendered without a model.
public struct InboxActions {
    public var open: (String) -> Void = { _ in }
    public var copyReply: (String) -> Void = { _ in }
    public var openAgentView: () -> Void = {}
    public var refresh: () -> Void = {}
    public var quit: () -> Void = {}
    /// Terminals the user can pick, as (identifier, name). Empty hides the chooser.
    public var terminals: [(id: String, name: String)] = []
    /// The picked terminal's identifier, or nil for "whichever is running".
    public var chosenTerminal: String?
    public var chooseTerminal: (String?) -> Void = { _ in }
    public var prefersAgentView = false
    public var setPrefersAgentView: (Bool) -> Void = { _ in }

    public init() {}
}

/// The dropdown under the menu-bar icon.
public struct InboxView: View {
    let snapshot: StoreSnapshot
    let now: Date
    let notice: String?
    let actions: InboxActions
    /// Off for offscreen rendering, which cannot draw a scroll view.
    let scrolls: Bool

    public init(snapshot: StoreSnapshot, now: Date = Date(), notice: String? = nil, actions: InboxActions = InboxActions(), scrolls: Bool = true) {
        self.snapshot = snapshot
        self.now = now
        self.notice = notice
        self.actions = actions
        self.scrolls = scrolls
    }

    public init(model: InboxModel, quit: @escaping () -> Void) {
        var actions = InboxActions()
        actions.open = { model.open(sessionID: $0) }
        actions.copyReply = { model.copyReply(sessionID: $0) }
        actions.openAgentView = { model.openAgentView() }
        actions.refresh = { model.refresh() }
        actions.quit = quit
        actions.terminals = model.installedTerminals.map { (id: $0.rawValue, name: $0.displayName) }
        actions.chosenTerminal = model.chosenTerminal?.rawValue
        actions.chooseTerminal = { id in model.chooseTerminal(id.flatMap { TerminalApp(rawValue: $0) }) }
        actions.prefersAgentView = model.prefersAgentView
        actions.setPrefersAgentView = { model.setPrefersAgentView($0) }
        self.init(snapshot: model.snapshot, now: model.now, notice: model.notice, actions: actions)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let stale = snapshot.staleNotice(now: now) {
                Label(stale, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Divider()
            }

            if scrolls {
                ScrollView { sessionList }
                    .frame(maxHeight: 460)
                    // The menu-bar window sizes its content to the minimum it will accept, and a
                    // scroll view accepts almost nothing. Fixing it at its ideal height (the
                    // list's height, up to the limit above) is what keeps the rows visible.
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                sessionList
            }

            Divider()
            footer
        }
        .frame(width: 400)
    }

    @ViewBuilder private var sessionList: some View {
        let sections = InboxGroups(sessions: snapshot.sessions, now: now).sections(now: now)
        VStack(alignment: .leading, spacing: 0) {
            if sections.isEmpty {
                Text(snapshot.fetchedAt == nil && !snapshot.isStale ? "Looking for sessions…" : "No background sessions")
                    .foregroundStyle(.secondary)
                    .padding(14)
            }
            ForEach(sections, id: \.title) { section in
                Text(section.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                ForEach(section.rows) { row in
                    InboxRowView(row: row, actions: actions)
                }
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Button("Open agent view", action: actions.openAgentView)
                Button("Refresh", action: actions.refresh)
                if !actions.terminals.isEmpty {
                    Menu(terminalLabel) {
                        terminalChoice("Whichever is running", id: nil)
                        Divider()
                        ForEach(actions.terminals, id: \.id) { terminal in
                            terminalChoice(terminal.name, id: terminal.id)
                        }
                        Divider()
                        Button {
                            actions.setPrefersAgentView(!actions.prefersAgentView)
                        } label: {
                            if actions.prefersAgentView {
                                Label("Use agent view when it is open", systemImage: "checkmark")
                            } else {
                                Text("Use agent view when it is open")
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Which terminal sessions open in")
                }
                Spacer()
                Button("Quit", action: actions.quit)
            }
            .buttonStyle(TextLinkStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

extension InboxView {
    var terminalLabel: String {
        let name = actions.terminals.first { $0.id == actions.chosenTerminal }?.name
        return "Terminal: \(name ?? "Auto")"
    }

    func terminalChoice(_ title: String, id: String?) -> some View {
        Button {
            actions.chooseTerminal(id)
        } label: {
            if actions.chosenTerminal == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

struct InboxRowView: View {
    let row: InboxRow
    let actions: InboxActions

    var body: some View {
        Button {
            actions.open(row.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let age = row.age {
                            Text(age)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                    Text(row.place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let detail = row.detail {
                        Text(detailText(detail))
                            .font(row.kind == .approval ? .callout.monospaced() : .callout)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 1)
                    }
                    if !row.options.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(row.options.enumerated()), id: \.offset) { index, option in
                                Text("\(index + 1). \(option)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in your terminal")

        if row.suggestedReply != nil {
            Button("Copy suggested reply") { actions.copyReply(row.id) }
                .buttonStyle(TextLinkStyle())
                .font(.callout)
                .padding(.leading, 42)
                .padding(.bottom, 6)
        }
    }

    private func detailText(_ detail: String) -> String {
        if row.kind == .approval, let tool = row.tool { return "\(tool): \(detail)" }
        return detail
    }

    private var symbol: String {
        switch row.kind {
        case .question: "questionmark.bubble.fill"
        case .approval: "hand.raised.fill"
        case .waiting: "hourglass"
        case .working: "gearshape.2"
        case .done: "checkmark.circle"
        case .unknown: "circle.dashed"
        }
    }

    private var tint: Color {
        switch row.kind {
        case .question, .approval, .waiting: .orange
        case .working: .blue
        case .done: .green
        case .unknown: .secondary
        }
    }
}

/// A text-only button in the accent colour. Drawn by SwiftUI itself, unlike the system link style,
/// so it also appears in offscreen renders.
struct TextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
