import Foundation
import Testing

@testable import PorchlightCore

@Suite struct SetupTests {
    /// Everything in place: nothing to do.
    var ready: SetupFacts {
        SetupFacts(
            claudePath: "/Users/u/.local/bin/claude", claudeCandidates: [], claudeVersion: CLIVersion([2, 1, 294]), hasWorkspaceRoot: true,
            notificationProblem: nil, hasShortcut: true, launchesAtLogin: true, hidden: false)
    }

    @Test func nothingIsShownWhenEverythingIsInPlace() {
        #expect(Setup.steps(for: ready).isEmpty)
        // A copy that cannot be a login item has nothing to offer about it.
        var bare = ready
        bare.launchesAtLogin = nil
        #expect(Setup.steps(for: bare).isEmpty)
    }

    @Test func aFreshInstallListsEveryOptionalStepWithItsButton() {
        var fresh = ready
        fresh.hasWorkspaceRoot = false
        fresh.hasShortcut = false
        fresh.launchesAtLogin = false
        fresh.notificationProblem = "Notifications are turned off for Porchlight in System Settings > Notifications."
        let steps = Setup.steps(for: fresh)
        #expect(steps.map(\.kind) == [.workspace, .notifications, .shortcut, .loginItem])
        #expect(steps.allSatisfy { !$0.isProblem && $0.action != nil })
        #expect(steps[1].detail == fresh.notificationProblem)
        #expect(steps[2].action == "Use ⌃⌥⌘N")
        #expect(Setup.canHide(steps))
    }

    @Test func aMissingClaudeIsAProblemThatHidingDoesNotHide() {
        var missing = ready
        missing.claudePath = nil
        missing.claudeCandidates = ["/a/claude", "/b/claude", "/c/claude", "/d/claude", "/e/claude"]
        missing.hasShortcut = false
        var steps = Setup.steps(for: missing)
        #expect(steps.map(\.kind) == [.claudeMissing, .shortcut])
        #expect(steps[0].isProblem && steps[0].action == nil)
        // It says where it looked, without listing every place.
        #expect(steps[0].detail.contains("/a/claude") && steps[0].detail.contains("/d/claude") && !steps[0].detail.contains("/e/claude"))

        missing.hidden = true
        steps = Setup.steps(for: missing)
        #expect(steps.map(\.kind) == [.claudeMissing])
        #expect(!Setup.canHide(steps))
    }

    @Test func anOldClaudeSaysWhichVersionAndHowToUpdate() {
        var old = ready
        old.claudeVersion = CLIVersion([2, 1, 200])
        let steps = Setup.steps(for: old)
        #expect(steps.map(\.kind) == [.claudeTooOld])
        #expect(steps[0].title == "Claude Code 2.1.200 is older than Porchlight expects")
        #expect(steps[0].detail.contains("2.1.294") && steps[0].detail.contains("claude update"))
        // The minimum itself, a newer one, and one that could not be read are all fine.
        for version in [CLIVersion([2, 1, 294]), CLIVersion([2, 2]), CLIVersion([3]), nil] {
            old.claudeVersion = version
            #expect(Setup.steps(for: old).isEmpty)
        }
    }

    @Test func hidingRemovesOnlyTheOptionalSteps() {
        var fresh = ready
        fresh.hasWorkspaceRoot = false
        fresh.launchesAtLogin = false
        fresh.hidden = true
        #expect(Setup.steps(for: fresh).isEmpty)
    }

    @Test func theHiddenFlagIsASettingReadTolerantly() throws {
        func load(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        #expect(try load(#"{"setupHidden": true}"#).setupHidden == true)
        #expect(try load(#"{"setupHidden": "yes", "terminal": "warp"}"#) == Settings(terminal: "warp"))
        #expect(try load("{}").setupHidden == nil)
    }

    @Test func exportedSettingsReadBackTheSame() throws {
        var settings = Settings(terminal: "ghostty", preferAgentView: true)
        settings.repos = RepoIndexSettings(roots: ["~/code"], pinned: ["~/code/a"])
        settings.naming = NamingSettings(template: "{repo}-{slug}")
        settings.hotkey = .suggested
        settings.setupHidden = true
        let data = try SettingsTransfer.export(settings)
        #expect(try SettingsTransfer.read(data) == settings)
        // What is written is the settings file itself, readable by hand.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"terminal\" : \"ghostty\"") && text.contains("~/code"))
    }

    @Test func aFileThatIsNotASettingsFileIsRefused() {
        for text in ["", "not json", "[1, 2]", "\"settings\"", "42"] {
            #expect(throws: SettingsTransfer.Failure.notSettings) { _ = try SettingsTransfer.read(Data(text.utf8)) }
        }
    }

    @Test func aSettingsFileWithOddOrUnknownEntriesIsTakenForWhatItHas() throws {
        let data = Data(#"{"terminal": "warp", "reminders": "often", "futureThing": {"a": 1}}"#.utf8)
        #expect(try SettingsTransfer.read(data) == Settings(terminal: "warp"))
        #expect(try SettingsTransfer.read(Data("{}".utf8)) == Settings())
    }
}
