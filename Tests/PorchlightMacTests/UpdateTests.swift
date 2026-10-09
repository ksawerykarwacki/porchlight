import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightMac
@testable import PorchlightUI

/// Stands in for git and Homebrew: records what was run and answers from a script.
final class CommandProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private var environments: [[String: String]] = []
    private var lsRemote: (Int32, String)
    private var upgrade: (Int32, String)

    init(lsRemote: (Int32, String), upgrade: (Int32, String) = (0, "==> Upgrading porchlight\n")) {
        self.lsRemote = lsRemote
        self.upgrade = upgrade
    }

    var calls: [[String]] { lock.withLock { recorded } }
    var passedEnvironments: [[String: String]] { lock.withLock { environments } }

    func setLsRemote(_ status: Int32, _ output: String) { lock.withLock { lsRemote = (status, output) } }

    var updater: AppUpdater {
        AppUpdater(brew: "/opt/homebrew/bin/brew") { executable, arguments, environment, _ in
            self.lock.withLock {
                self.recorded.append([executable] + arguments)
                self.environments.append(environment)
                return executable.hasSuffix("/git") ? self.lsRemote : self.upgrade
            }
        }
    }
}

@MainActor
@Suite struct AppUpdateTests {
    static let cellar = "/opt/homebrew/Cellar/porchlight/HEAD-98deba5/Porchlight.app/"
    static let newer = "0123456789abcdef0123456789abcdef01234567"
    static let same = "98deba595f5c405c5461f48e32363b654f1f819e"

    @Test func theInstalledCommitIsReadFromTheHomebrewPath() {
        #expect(AppVersion.installedCommit(bundlePath: Self.cellar) == "98deba5")
        #expect(AppVersion.installedCommit(bundlePath: "/usr/local/Cellar/porchlight/HEAD-0a1b2c3d4e/Porchlight.app/") == "0a1b2c3d4e")
        // The link Homebrew's service starts the app through names no commit: resolve it first.
        #expect(AppVersion.installedCommit(bundlePath: "/opt/homebrew/opt/porchlight/Porchlight.app/") == nil)
        // Built by hand, a tagged version, or another formula: not a HEAD install of this one.
        for path in ["/Users/u/code/porchlight/dist/Porchlight.app/", "/opt/homebrew/Cellar/porchlight/1.2.0/Porchlight.app/",
                     "/opt/homebrew/Cellar/other/HEAD-98deba5/Other.app/", "/opt/homebrew/Cellar/porchlight/HEAD-xyz/Porchlight.app/"] {
            #expect(AppVersion.installedCommit(bundlePath: path) == nil, "\(path)")
        }
    }

    @Test func theLatestCommitIsReadFromLsRemoteAndComparedByPrefix() {
        #expect(AppVersion.latestCommit(lsRemote: "\(Self.same)\trefs/heads/main\n") == Self.same)
        #expect(AppVersion.latestCommit(lsRemote: "") == nil)
        #expect(AppVersion.latestCommit(lsRemote: "fatal: could not read Username for 'https://github.com'") == nil)
        #expect(AppVersion.latestCommit(lsRemote: "98deba5\trefs/heads/main") == nil)
        #expect(!AppVersion.isNewer(latest: Self.same, installed: "98deba5"))
        #expect(!AppVersion.isNewer(latest: Self.same.uppercased(), installed: "98deba5"))
        #expect(AppVersion.isNewer(latest: Self.newer, installed: "98deba5"))
        #expect(!AppVersion.isNewer(latest: Self.newer, installed: ""))
        #expect(AppVersion.brew(isExecutable: { $0 == "/usr/local/bin/brew" }) == "/usr/local/bin/brew")
        #expect(AppVersion.brew(isExecutable: { _ in false }) == nil)
    }

    @Test func aCopyNotInstalledByHomebrewOffersNoUpdatesAndRunsNothing() async {
        let probe = CommandProbe(lsRemote: (0, "\(Self.newer)\trefs/heads/main"))
        let model = UpdateModel(bundlePath: "/Users/u/code/porchlight/dist/Porchlight.app/", updater: probe.updater)
        #expect(model.installed == nil && model.state == .unavailable)
        #expect(model.summary == "Not installed with Homebrew, so updates are off.")
        await model.check()
        await model.update()
        #expect(probe.calls.isEmpty && model.state == .unavailable)
    }

    @Test func checkingAsksGitWithoutAPromptAndComparesWithWhatIsInstalled() async {
        let probe = CommandProbe(lsRemote: (0, "\(Self.same)\trefs/heads/main\n"))
        let model = UpdateModel(bundlePath: Self.cellar, updater: probe.updater)
        #expect(model.state == .unknown && model.summary == "Installed: 98deba5")
        await model.check()
        #expect(model.state == .upToDate && !model.canUpdate)
        #expect(probe.calls == [["/usr/bin/git", "ls-remote", "https://github.com/ksawerykarwacki/porchlight.git", "refs/heads/main"]])
        // git must fail rather than wait for a password nobody can type.
        #expect(probe.passedEnvironments == [["GIT_TERMINAL_PROMPT": "0"]])

        probe.setLsRemote(0, "\(Self.newer)\trefs/heads/main\n")
        await model.check()
        #expect(model.state == .available(latest: Self.newer) && model.canUpdate)
        #expect(model.summary == "A newer version is available: 0123456 (installed: 98deba5).")
    }

    @Test func aCheckThatFailsSaysWhyAndOffersNoUpdate() async {
        let probe = CommandProbe(lsRemote: (128, "remote: Repository not found.\nfatal: repository 'https://github.com/x/y.git/' not found\n"))
        let model = UpdateModel(bundlePath: Self.cellar, updater: probe.updater)
        await model.check()
        #expect(model.state == .failed("Could not check for updates: fatal: repository 'https://github.com/x/y.git/' not found"))
        #expect(!model.canUpdate)
        await model.update()
        #expect(probe.calls.count == 1)
    }

    @Test func updatingRunsHomebrewOnTheFullyNamedFormulaThenRestarts() async {
        let probe = CommandProbe(lsRemote: (0, "\(Self.newer)\trefs/heads/main"))
        let model = UpdateModel(bundlePath: Self.cellar, updater: probe.updater)
        var restarts = 0
        model.restart = { restarts += 1 }
        // Nothing to install until a check has found something.
        await model.update()
        #expect(probe.calls.isEmpty && restarts == 0)

        await model.check()
        await model.update()
        #expect(probe.calls.last == ["/opt/homebrew/bin/brew", "upgrade", "--fetch-HEAD", "ksawerykarwacki/porchlight/porchlight"])
        #expect(model.state == .restarting && restarts == 1)
        // While restarting, another check does not start.
        await model.check()
        #expect(probe.calls.count == 2)
    }

    @Test func aFailedUpdateShowsTheEndOfWhatHomebrewSaidAndDoesNotRestart() async {
        let output = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\nError: porchlight HEAD did not build\n"
        let probe = CommandProbe(lsRemote: (0, "\(Self.newer)\trefs/heads/main"), upgrade: (1, output))
        let model = UpdateModel(bundlePath: Self.cellar, updater: probe.updater)
        var restarts = 0
        model.restart = { restarts += 1 }
        await model.check()
        await model.update()
        guard case .failed(let message) = model.state else {
            Issue.record("expected a failure, got \(model.state)")
            return
        }
        #expect(message.hasPrefix("The update did not finish. Homebrew said:"))
        #expect(message.hasSuffix("Error: porchlight HEAD did not build") && !message.contains("line 3\n"))
        #expect(restarts == 0)

        let noBrew = UpdateModel(bundlePath: Self.cellar, updater: AppUpdater(brew: nil, run: probe.updater.run))
        await noBrew.check()
        await noBrew.update()
        #expect(noBrew.state == .failed("Homebrew was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew."))
    }

    /// What the owner saw on 2026-10-09: the message ended in lines of Homebrew's sandbox profile.
    @Test func aFailureInsideHomebrewsSandboxShowsTheErrorNotTheSandboxProfile() async {
        let output = """
            ==> Fetching downloads for: porchlight
            Failure while executing; `/usr/bin/env HOME=/Users/u /usr/bin/sandbox-exec -p \\(version\\ 1\\)'
            '\\(debug\\ deny\\)'
            '\\ \\ \\ \\ \\(with\\ no-sandbox\\)'
            '\\(allow\\ default\\)\\ \\;\\ allow\\ everything\\ else'
            ' git fetch origin` exited with 128. Here's the output:
            error: unable to read askpass response from '/usr/bin/false'
            fatal: could not read Username for 'https://github.com': terminal prompts disabled
            """
        let probe = CommandProbe(lsRemote: (0, "\(Self.newer)\trefs/heads/main"), upgrade: (1, output))
        let model = UpdateModel(bundlePath: Self.cellar, updater: probe.updater)
        await model.check()
        await model.update()
        guard case .failed(let message) = model.state else {
            Issue.record("expected a failure")
            return
        }
        #expect(message.contains("fatal: could not read Username for 'https://github.com'"))
        #expect(message.contains("error: unable to read askpass response"))
        #expect(!message.contains("no-sandbox") && !message.contains("allow\\ default") && !message.contains("sandbox-exec"))
    }

    @Test func theNewCopyIsStartedThroughTheServiceWhenThereIsOneAndOpenedOtherwise() {
        #expect(AppRestart.command(serviceIsLoaded: true, brew: "/opt/homebrew/bin/brew")
            == ["/opt/homebrew/bin/brew", "services", "restart", "ksawerykarwacki/porchlight/porchlight"])
        let opened = AppRestart.command(serviceIsLoaded: false, brew: "/usr/local/bin/brew", prefix: "/usr/local")
        #expect(opened.first == "/bin/sh" && opened.last == "/usr/local/opt/porchlight/Porchlight.app")
        // The path is an argument to the shell, never part of the line it runs.
        #expect(opened[2] == "sleep 1; /usr/bin/open -n \"$0\"")
        #expect(AppRestart.command(serviceIsLoaded: true, brew: nil).first == "/bin/sh")
        // A detached child really runs, and a missing program is reported.
        #expect(AppRestart.spawnDetached(["/usr/bin/true"]))
        #expect(!AppRestart.spawnDetached(["/nonexistent/program"]))
        #expect(!AppRestart.spawnDetached([]))
    }

    @Test func theSettingsTabShowsUpdatesOnlyWhenThereIsSomethingToSay() throws {
        func height(_ actions: InboxActions) throws -> CGFloat {
            try #require(ImageRenderer(content: SettingsPage(actions: actions, drawsMenus: false, timeSensitive: .unknown).frame(width: 400)).nsImage).size.height
        }
        let plain = try height(InboxActions())
        var notHomebrew = InboxActions()
        notHomebrew.updateSummary = "Not installed with Homebrew, so updates are off."
        let off = try height(notHomebrew)
        // A heading and a line, no buttons.
        #expect(off > plain + 30)

        var available = InboxActions()
        available.updateSummary = "A newer version is available: 0123456 (installed: 98deba5)."
        available.installedWithHomebrew = true
        available.canUpdate = true
        let withButtons = try height(available)
        // The buttons, and the line that says Homebrew starts the app at login.
        #expect(withButtons > off + 30)
        available.updateIsBusy = true
        #expect(try height(available) < withButtons)

        var pressed: [String] = []
        available.checkForUpdate = { pressed.append("check") }
        available.installUpdate = { pressed.append("install") }
        available.checkForUpdate()
        available.installUpdate()
        #expect(pressed == ["check", "install"])
    }
}
