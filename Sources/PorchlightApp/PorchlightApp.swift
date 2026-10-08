import PorchlightUI
import SwiftUI

@main
struct PorchlightApp: App {
    // Not `@State`: on the macOS 27 SDK it is a macro whose compiler plugin ships only with Xcode,
    // and this package must build with the Command Line Tools alone. State lives in @Observable
    // models instead.
    private let model: InboxModel

    init() {
        let model = InboxModel()
        self.model = model
        Task { await model.run() }
    }

    var body: some Scene {
        MenuBarExtra {
            InboxView(model: model, quit: { NSApplication.shared.terminate(nil) })
        } label: {
            Label(model.waitingCount > 0 ? "\(model.waitingCount)" : "", systemImage: model.waitingCount > 0 ? "lightbulb.fill" : "lightbulb")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
