import PorchlightCore
import SwiftUI

@main
struct PorchlightApp: App {
    // Not `@State`: on the macOS 27 SDK it is a macro whose compiler plugin ships only with Xcode,
    // and this package must build with the Command Line Tools alone. State lives in @Observable
    // models instead.
    private let model = InboxModel()

    var body: some Scene {
        MenuBarExtra {
            InboxMenu(model: model)
        } label: {
            Label(model.waitingCount > 0 ? "\(model.waitingCount)" : "", systemImage: model.waitingCount > 0 ? "lightbulb.fill" : "lightbulb")
                .labelStyle(.titleAndIcon)
        }
    }
}

/// M0 skeleton: polls the CLI and lists sessions. The real inbox (grouping, actions) is M1.
@MainActor
@Observable
final class InboxModel {
    private(set) var sessions: [Session] = []
    private(set) var problem: String?

    var waitingCount: Int { sessions.filter(\.needsHuman).count }

    init() {
        Task { await self.poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    func refresh() async {
        guard let claude = ClaudeLocator().locate() else {
            problem = "claude not found"
            return
        }
        do {
            let snapshot = try await AgentsCLISource(executable: claude).snapshot()
            sessions = JobStateSource().enrich(snapshot.sessions)
            problem = nil
        } catch {
            // Keep the last good snapshot; just say it is stale.
            problem = "could not refresh sessions"
        }
    }
}

struct InboxMenu: View {
    let model: InboxModel

    var body: some View {
        if let problem = model.problem {
            Text(problem)
            Divider()
        }
        let waiting = model.sessions.filter(\.needsHuman)
        if waiting.isEmpty {
            Text("Nothing is waiting on you")
        } else {
            Text("Needs you")
            ForEach(waiting) { session in
                Text("\(session.name) — \(session.location.repoName)")
            }
        }
        Divider()
        Button("Refresh") { Task { await model.refresh() } }
        Button("Quit Porchlight") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
