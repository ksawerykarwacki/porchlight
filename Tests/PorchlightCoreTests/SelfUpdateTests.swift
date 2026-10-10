import Foundation
import Testing

@testable import PorchlightCore

@Suite struct SelfUpdateTests {
    @Test func theInstalledModsAreReadFromClaudeCodesList() {
        let list = """
            [{"id":"cloudflare@cloudflare","version":"1.0.1"},
             {"id":"porchlight-wake@porchlight","version":"0.1.0"},
             {"id":"porchlight-companion@porchlight","version":"0.3.0"},
             {"id":"porchlight@elsewhere"}, {"id":"@porchlight"}, {"version":"1"}]
            """
        #expect(SelfUpdate.installedMods(pluginList: list) == ["porchlight-companion", "porchlight-wake"])
        // Not that list at all: none, rather than a guess.
        #expect(SelfUpdate.installedMods(pluginList: "") == [] && SelfUpdate.installedMods(pluginList: "No plugins installed") == [])
        #expect(SelfUpdate.installedMods(pluginList: #"{"id":"porchlight-wake@porchlight"}"#) == [])
    }

    @Test func theAppIsBuiltFromTheFullyQualifiedFormulaAndOnlyInstalledModsAreUpdated() {
        let upgrade = SelfUpdate.upgrade(brew: "/opt/homebrew/bin/brew")
        #expect(upgrade.arguments == ["/opt/homebrew/bin/brew", "upgrade", "--fetch-HEAD", "ksawerykarwacki/porchlight/porchlight"])
        #expect(upgrade.timeout >= 600)

        let steps = SelfUpdate.modSteps(claude: "/bin/claude", installed: ["porchlight-companion"])
        #expect(steps.map(\.arguments) == [
            ["/bin/claude", "plugin", "marketplace", "update", "porchlight"],
            ["/bin/claude", "plugin", "update", "porchlight-companion@porchlight"],
        ])
        // Homebrew's own name for its service comes first; the older one is still looked for.
        #expect(AppVersion.serviceLabels == ["sh.brew.porchlight", "homebrew.mxcl.porchlight"])
        // Started again when the build changed, or when an older build is the one running.
        let old = "/opt/homebrew/Cellar/porchlight/HEAD-aaaaaaa"
        let new = "/opt/homebrew/Cellar/porchlight/HEAD-bbbbbbb"
        #expect(SelfUpdate.needsRestart(installedBefore: old, installedNow: new, running: ["\(old)/Porchlight.app"]))
        #expect(SelfUpdate.needsRestart(installedBefore: new, installedNow: new, running: ["\(old)/Porchlight.app"]))
        #expect(SelfUpdate.needsRestart(installedBefore: new, installedNow: new, running: ["\(new)/Porchlight.app", "\(old)/Porchlight.app"]))
        #expect(!SelfUpdate.needsRestart(installedBefore: new, installedNow: new, running: ["\(new)/Porchlight.app"]))
        // Nothing running: nothing to replace.
        #expect(!SelfUpdate.needsRestart(installedBefore: old, installedNow: new, running: []))
        // With none installed nothing is asked of Claude Code at all.
        #expect(SelfUpdate.modSteps(claude: "/bin/claude", installed: []).isEmpty)
    }
}
