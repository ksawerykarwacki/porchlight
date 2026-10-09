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
    private let updates: UpdateModel
    private let hotkey = GlobalHotkey()

    init() {
        let updates = UpdateModel()
        self.updates = updates
        updates.restart = { AppRestart.relaunch() }
        Task { await updates.run() }
        // A Homebrew install is started at login by Homebrew's service, not by the app itself.
        let model = updates.installed == nil ? InboxModel() : InboxModel(loginItem: .unavailable)
        self.model = model
        model.willOpenTerminal = { PanelWindowObserver.closePanelAndLetGo() }
        model.pickFolder = {
            let dialog = NSOpenPanel()
            dialog.canChooseDirectories = true
            dialog.canChooseFiles = false
            dialog.prompt = "Search This Folder"
            dialog.message = "Choose the folder your repositories live in."
            NSApp.activate(ignoringOtherApps: true)
            return dialog.runModal() == .OK ? dialog.url?.path : nil
        }
        model.openNotificationSettings = {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        Task { await model.refreshSetup() }
        Task { await model.run() }

        let services = PaletteServices.live(
            locator: { model.claudeLocator },
            sessionDirectories: { await model.sessionDirectories },
            sessions: { await model.rows })
        let paletteModel = PaletteModel(services: services)
        paletteModel.onStarted = { started, open in Task { await model.sessionStarted(started, open: open) } }
        paletteModel.onOpen = { started in model.open(sessionID: started.id) }
        paletteModel.onOpenSession = { id in model.open(sessionID: id) }
        paletteModel.onCopyReply = { id in model.copyReply(sessionID: id) }
        paletteModel.onSnooze = { id, choice in await model.snooze(sessionID: id, choice) }
        paletteModel.onRetry = { id in model.retry(sessionID: id) }
        paletteModel.onControl = { pending in await model.control(pending) }
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
                updates: updates,
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
