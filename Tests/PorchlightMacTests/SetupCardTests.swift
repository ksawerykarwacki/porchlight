import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightMac
@testable import PorchlightUI

/// A login item that remembers what was asked of it.
final class LoginItemProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled: Bool?
    private var refusal: String?
    private var asked: [Bool] = []

    init(enabled: Bool?, refusal: String? = nil) {
        self.enabled = enabled
        self.refusal = refusal
    }

    var requests: [Bool] { lock.withLock { asked } }

    var item: LoginItem {
        LoginItem(
            isEnabled: { self.lock.withLock { self.enabled } },
            set: { value in
                self.lock.withLock {
                    self.asked.append(value)
                    if self.refusal == nil { self.enabled = value }
                    return self.refusal
                }
            })
    }
}

@MainActor
@Suite struct LoginItemTests {
    @Test func aBareExecutableCannotBeALoginItemAndSaysSo() {
        let item = LoginItem.live(isBundled: false)
        #expect(item.isEnabled() == nil)
        #expect(item.set(true)?.contains("not an app") == true)
        // The test runner is not an app bundle either, so the default asks the system nothing.
        #expect(LoginItem.live().isEnabled() == nil)
    }

    func model(_ probe: LoginItemProbe) throws -> (InboxModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Settings.fileURL(in: directory)
        let locator = ClaudeLocator(override: "/bin/echo", environment: [:], homeDirectory: "/nowhere")
        let model = InboxModel(locator: locator, settingsURL: url, remindersURL: ReminderState.fileURL(in: directory), loginItem: probe.item)
        model.readClaudeVersion = { _ in CLIVersion([2, 1, 294]) }
        return (model, url)
    }

    @Test func switchingItOnAsksTheSystemOnceAndTheStepGoesAway() async throws {
        let probe = LoginItemProbe(enabled: false)
        let (model, _) = try model(probe)
        await model.refreshSetup()
        #expect(model.setupSteps.contains { $0.kind == .loginItem })
        await model.performSetup(.loginItem)
        #expect(probe.requests == [true])
        #expect(!model.setupSteps.contains { $0.kind == .loginItem })
        #expect(model.notice == "Porchlight will open at login")
    }

    @Test func aRefusalIsReportedAndTheStepStays() async throws {
        let probe = LoginItemProbe(enabled: false, refusal: "Allow Porchlight under System Settings > General > Login Items.")
        let (model, _) = try model(probe)
        await model.refreshSetup()
        await model.performSetup(.loginItem)
        #expect(probe.requests == [true])
        #expect(model.notice == "Allow Porchlight under System Settings > General > Login Items.")
        #expect(model.setupSteps.contains { $0.kind == .loginItem })
    }
}

@MainActor
@Suite struct SetupCardTests {
    func model(claude: String? = "/bin/echo", version: CLIVersion? = CLIVersion([2, 1, 294])) throws -> (InboxModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Settings.fileURL(in: directory)
        let locator = ClaudeLocator(override: claude, environment: [:], homeDirectory: "/nowhere", isExecutable: { $0 == claude })
        let model = InboxModel(
            locator: locator, settingsURL: url, remindersURL: ReminderState.fileURL(in: directory), loginItem: LoginItemProbe(enabled: false).item)
        model.readClaudeVersion = { _ in version }
        model.registerHotkey = { _ in true }
        return (model, url)
    }

    @Test func aFreshInstallShowsTheOptionalStepsAndEachButtonDoesItsStep() async throws {
        let (model, url) = try model()
        await model.refreshSetup()
        #expect(model.setupSteps.map(\.kind) == [.workspace, .shortcut, .loginItem])

        // The shortcut button registers and saves the suggested shortcut.
        await model.performSetup(.shortcut)
        #expect(model.hotkey == .suggested && Settings.load(from: url).hotkey == .suggested)
        #expect(model.setupSteps.map(\.kind) == [.workspace, .loginItem])

        // The folder button asks for a folder and saves it as a workspace root.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-root-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        model.pickFolder = { folder }
        await model.performSetup(.workspace)
        #expect(Settings.load(from: url).repos?.roots.count == 1)
        #expect(model.setupSteps.map(\.kind) == [.loginItem])

        // Cancelling the folder dialog changes nothing.
        let (other, otherURL) = try self.model()
        other.pickFolder = { nil }
        await other.performSetup(.workspace)
        #expect(Settings.load(from: otherURL).repos == nil)
    }

    @Test func theSameStepsLiveOnTheSettingsTabAfterTheCardIsHidden() async throws {
        let probe = LoginItemProbe(enabled: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-general-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Settings.fileURL(in: directory)
        let locator = ClaudeLocator(override: "/bin/echo", environment: [:], homeDirectory: "/nowhere", isExecutable: { $0 == "/bin/echo" })
        let model = InboxModel(locator: locator, settingsURL: url, remindersURL: ReminderState.fileURL(in: directory), loginItem: probe.item)
        model.readClaudeVersion = { _ in CLIVersion([2, 1, 294]) }
        model.hideSetup()
        await model.refreshSetup()
        #expect(model.setupSteps.isEmpty)

        // Open at login, switched on and off from Settings.
        #expect(model.setupFacts.launchesAtLogin == false)
        await model.setLaunchesAtLogin(true)
        #expect(probe.requests == [true] && model.setupFacts.launchesAtLogin == true)
        await model.setLaunchesAtLogin(false)
        #expect(probe.requests == [true, false] && model.setupFacts.launchesAtLogin == false)
        #expect(model.notice == "Porchlight will no longer open at login")

        // Workspace folders: added through the same step the card used, listed, and removable.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-root-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        model.pickFolder = { folder }
        await model.performSetup(.workspace)
        #expect(model.workspaceRoots.count == 1)
        await model.removeWorkspaceRoot(model.workspaceRoots[0])
        #expect(model.workspaceRoots.isEmpty && Settings.load(from: url).repos?.roots.isEmpty == true)
    }

    @Test func theSettingsPageHasAGeneralSectionThatGrowsWithItsFolders() throws {
        func height(_ actions: InboxActions) throws -> CGFloat {
            try #require(ImageRenderer(content: SettingsPage(actions: actions, drawsMenus: false, timeSensitive: .unknown).frame(width: 400)).nsImage).size.height
        }
        var actions = InboxActions()
        actions.workspaceRoots = ["~/code"]
        let one = try height(actions)
        actions.workspaceRoots = ["~/code", "~/work", "~/play"]
        let two = try height(actions)
        // Each folder is a row of its own.
        #expect(two > one + 30)
        actions.launchesAtLogin = true
        let withLogin = try height(actions)
        #expect(withLogin > two + 15)
        actions.notificationProblem = "Notifications are turned off for Porchlight in System Settings > Notifications."
        #expect(try height(actions) > withLogin + 40)
    }

    @Test func notificationsOpenTheSystemSettings() async throws {
        let (model, _) = try model()
        var opened = 0
        model.openNotificationSettings = { opened += 1 }
        await model.performSetup(.notifications)
        #expect(opened == 1)
    }

    @Test func hidingIsRememberedButAMissingClaudeStillShows() async throws {
        let (model, url) = try model()
        await model.refreshSetup()
        model.hideSetup()
        #expect(model.setupSteps.isEmpty)
        #expect(Settings.load(from: url).setupHidden == true)
        // Still hidden after the facts are gathered again, as after a restart.
        await model.refreshSetup()
        #expect(model.setupSteps.isEmpty)

        let (broken, _) = try self.model(claude: nil)
        broken.hideSetup()
        await broken.refreshSetup()
        #expect(broken.setupSteps.map(\.kind) == [.claudeMissing])
    }

    @Test func anOldClaudeIsReportedWithItsVersion() async throws {
        let (model, _) = try model(version: CLIVersion([2, 0, 9]))
        await model.refreshSetup()
        #expect(model.setupSteps.first?.kind == .claudeTooOld)
        #expect(model.setupSteps.first?.title.contains("2.0.9") == true)
    }

    @Test func theCardIsDrawnAboveTheSessionsOnlyWhenThereIsSomethingToDo() async throws {
        func height(_ actions: InboxActions) throws -> CGFloat {
            let view = InboxView(snapshot: StoreSnapshot(), actions: actions, scrolls: false)
            return try #require(ImageRenderer(content: view.background(Color.white)).nsImage).size.height
        }
        let plain = try height(InboxActions())
        var actions = InboxActions()
        actions.setupSteps = Setup.steps(for: SetupFacts(claudePath: "/x/claude", hasWorkspaceRoot: false, hasShortcut: false, launchesAtLogin: false))
        #expect(actions.setupSteps.count == 3)
        let three = try height(actions)
        // Three steps, each a title, a line of detail and a button, plus the hide button.
        #expect(three > plain + 3 * 50)
        actions.setupSteps = Array(actions.setupSteps.prefix(1))
        let one = try height(actions)
        #expect(one > plain + 50 && one < three - 80)

        var pressed: [SetupStep.Kind] = []
        actions.performSetup = { pressed.append($0) }
        actions.performSetup(.workspace)
        #expect(pressed == [.workspace])
    }
}
