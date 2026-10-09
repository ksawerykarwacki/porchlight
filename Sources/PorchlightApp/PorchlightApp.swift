import PorchlightCore
import PorchlightMac
import PorchlightUI
import SwiftUI

@main
struct PorchlightApp: App {
    // Not `@State`: on the macOS 27 SDK it is a macro whose compiler plugin ships only with Xcode,
    // and this package must build with the Command Line Tools alone. State lives in @Observable
    // models instead.
    private let model: InboxModel
    private let palette: PaletteController
    private let hotkey = GlobalHotkey()

    init() {
        let model = InboxModel()
        self.model = model
        model.willOpenTerminal = { PanelWindowObserver.closePanelAndLetGo() }
        Task { await model.run() }

        let services = PaletteServices.live(
            locator: { model.claudeLocator },
            sessionDirectories: { await model.sessionDirectories })
        let paletteModel = PaletteModel(services: services)
        paletteModel.onStarted = { started, open in Task { await model.sessionStarted(started, open: open) } }
        paletteModel.onOpen = { started in model.open(sessionID: started.id) }
        paletteModel.onTrust = { folder in model.openToTrust(folder: folder) }
        paletteModel.onCopy = { command in model.copy(command, saying: "Command copied") }
        let palette = PaletteController(model: paletteModel)
        self.palette = palette
        // `porchlight new` asks the running app for the palette; so can any launcher or shortcut tool.
        AppSignal.observe(.newSession) { palette.show() }
        let hotkey = hotkey
        model.registerHotkey = { shortcut in hotkey.set(shortcut) { palette.toggle() } }
        model.registerSavedHotkey()
    }

    var body: some Scene {
        MenuBarExtra {
            InboxView(
                model: model,
                // The palette replaces the panel rather than opening beside it.
                newSession: {
                    PanelWindowObserver.closePanel()
                    palette.show()
                },
                quit: { NSApplication.shared.terminate(nil) })
                // Keeps the panel attached to the menu bar when its height changes, and brings
                // it back to the sessions the next time it opens.
                .background(PanelWindowObserver { model.showsSettings = false })
        } label: {
            StatusLabel(status: model.status)
        }
        .menuBarExtraStyle(.window)
    }
}
