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

/// Mirrors the session store onto the main actor for the views.
@MainActor
@Observable
final class InboxModel {
    private let store = SessionStore.live()
    private(set) var snapshot = StoreSnapshot()

    var sessions: [Session] { snapshot.sessions }
    var waitingCount: Int { snapshot.waitingCount }
    var problem: String? { snapshot.isStale ? "could not refresh sessions" : nil }

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
        await store.refresh()
        snapshot = await store.snapshot
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
