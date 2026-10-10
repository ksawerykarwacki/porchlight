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
    private let triage: TriageModel
    private let hotkey = GlobalHotkey()
    private let companionListener: CompanionListener?

    init() {
        // Before anything is started: an app opened at login has almost no PATH, and Claude Code
        // hands the environment of whoever starts its supervisor to every session.
        ShellEnvironment.adopt()
        let updates = UpdateModel()
        self.updates = updates
        updates.restart = { AppRestart.relaunch() }
        Task { await updates.run() }
        // A Homebrew install is started at login by Homebrew's service, not by the app itself.
        // Listening before the first read, so a session that reports at once is not missed.
        let hub = CompanionHub()
        var listener: CompanionListener?
        var companionProblem: String?
        do {
            let started = CompanionListener(hub: hub)
            try started.start()
            listener = started
        } catch CompanionListener.StartFailure.alreadyRunning {
            companionProblem = "another copy of Porchlight is already listening."
        } catch {
            companionProblem = "the socket could not be opened."
        }
        self.companionListener = listener
        let store = SessionStore.live(companion: hub)
        let model = updates.installed == nil ? InboxModel(store: store, companion: hub) : InboxModel(store: store, loginItem: .unavailable, companion: hub)
        model.companionProblem = companionProblem
        // Only ever called with a choice the user made and sent in the panel.
        if let listener { model.sendToCompanion = { command, conversation in listener.send(command, to: conversation) } }
        self.model = model
        model.willOpenTerminal = { PanelWindowObserver.closePanelAndLetGo() }
        let settingsURL = Settings.fileURL()
        let savedWrapUp = Settings.load(from: settingsURL).wrapUp ?? WrapUpSettings()
        self.triage = TriageModel(services: TriageModel.Services(
            sessions: { model.snapshot.sessions }, pins: { model.pins },
            settings: { Settings.load(from: settingsURL).triage ?? TriageSettings() },
            remove: { id in await model.removePlainly(sessionID: id) },
            reload: { await model.reload() },
            // Only reached after the question in the Triage row has been answered with yes.
            wrapUp: { item, engine, name in
                let settings = Settings.load(from: settingsURL)
                return await WrapUpRunner(claude: ClaudeLocator(override: settings.claudePath).locate()).wrapUp(
                    item.session, engine: engine, model: name, branch: item.facts.branch,
                    pullRequest: item.facts.branch == nil ? nil : item.facts.pullRequest.summary)
            },
            notes: { NotesArchive().all() },
            wrapUpPlan: {
                let settings = Settings.load(from: settingsURL).wrapUp ?? WrapUpSettings()
                return WrapUpPlan(chosen: settings.engine, model: settings.model, onDevice: await OnDeviceModel().status())
            }),
            // The saved choice at once; whether this Mac has the model follows a moment later.
            plan: WrapUpPlan(chosen: savedWrapUp.engine, model: savedWrapUp.model, onDevice: .missing))
        let triage = self.triage
        Task { await triage.refreshPlan() }
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
        paletteModel.onResume = { note in model.resume(note) }
        paletteModel.onRetry = { id in model.retry(sessionID: id) }
        paletteModel.onTogglePin = { id in model.togglePin(sessionID: id) }
        paletteModel.onControl = { pending in await model.control(pending) }
        paletteModel.onTrust = { folder in model.openToTrust(folder: folder) }
        paletteModel.onCopy = { command in model.copy(command, saying: "Command copied") }
        let palette = PaletteController(model: paletteModel)
        self.palette = palette
        // `porchlight new` asks the running app for the palette; so can any launcher or shortcut tool.
        AppSignal.observe(.newSession) { palette.show() }
        // A click on the daily summary: the palette lists what is waiting.
        model.showInbox = { palette.show() }
        let hotkey = hotkey
        model.registerHotkey = { shortcut in hotkey.set(shortcut) { palette.toggle() } }
        model.registerSavedHotkey()
    }

    var body: some Scene {
        MenuBarExtra {
            InboxView(
                model: model,
                updates: updates,
                triage: triage,
                // The palette replaces the panel rather than opening beside it.
                newSession: {
                    PanelWindowObserver.closePanel()
                    palette.show()
                },
                showNotes: {
                    PanelWindowObserver.closePanel()
                    palette.show(notes: true)
                },
                quit: { [companionListener] in
                    // Gone on purpose: leave nothing for a mod to find or talk to.
                    companionListener?.stop()
                    NSApplication.shared.terminate(nil)
                })
                // Keeps the panel attached to the menu bar when its height changes, and brings
                // it back to the sessions the next time it opens.
                .background(PanelWindowObserver {
                    model.showsSettings = false
                    model.showsTriage = false
                })
        } label: {
            StatusLabel(status: model.status)
        }
        .menuBarExtraStyle(.window)
    }
}
