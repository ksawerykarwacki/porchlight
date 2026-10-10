#if canImport(PorchlightMac)
import Foundation
import PorchlightCore
import PorchlightMac

/// `porchlight update [--app | --mods]`: what the Update button in Settings does, and the mods
/// too: build the latest app with Homebrew, start it in place of the running one, and update the
/// Porchlight mods installed in Claude Code.
func update(arguments: [String]) async {
    let usage = "usage: porchlight update [--app | --mods]"
    guard arguments.allSatisfy({ $0 == "--app" || $0 == "--mods" }), arguments.count <= 1 else { fail(usage, code: 2) }
    let wantsApp = arguments.first != "--mods"
    let wantsMods = arguments.first != "--app"
    var failed = false

    /// Runs one step, saying what it is and, if it fails, the end of what it printed.
    func run(_ step: SelfUpdate.Step) async -> Bool {
        print("\(step.title)…")
        fflush(stdout)
        let result = try? await CLIRunner().run(URL(fileURLWithPath: step.arguments[0]), Array(step.arguments.dropFirst()), timeout: step.timeout)
        guard let result, result.succeeded else {
            print("  failed: \(AppUpdaterText.tail((result?.stdout ?? "") + (result?.stderr ?? "")))")
            failed = true
            return false
        }
        return true
    }

    if wantsApp {
        if let brew = AppVersion.brew() {
            let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent().path
            let link = "\(prefix)/opt/porchlight"
            // Homebrew installs each commit in a folder of its own: a changed path is a new build.
            let before = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
            if await run(SelfUpdate.upgrade(brew: brew)) {
                let after = URL(fileURLWithPath: link).resolvingSymlinksInPath().path
                if after == before {
                    print("  Porchlight is already the latest.")
                } else {
                    let restart = AppRestart.command(serviceIsLoaded: AppRestart.serviceIsLoaded(), brew: brew, prefix: prefix)
                    _ = await run(SelfUpdate.Step(title: "Starting the new Porchlight", arguments: restart))
                }
            }
        } else {
            print("Homebrew was not found; the app was not updated.")
            failed = true
        }
    }

    if wantsMods {
        if let claude = ClaudeLocator().locate() {
            let list = try? await CLIRunner().run(URL(fileURLWithPath: claude.path), ["plugin", "list", "--json"], timeout: 60)
            let installed = SelfUpdate.installedMods(pluginList: list?.stdout ?? "")
            if installed.isEmpty {
                print("No Porchlight mod is installed in Claude Code.")
            } else {
                for step in SelfUpdate.modSteps(claude: claude.path, installed: installed) { _ = await run(step) }
                print("Sessions that are running use the new mods after /reload-plugins; new sessions use them at once.")
            }
        } else {
            print("The claude command was not found; the mods were not updated.")
            failed = true
        }
    }
    exit(failed ? 1 : 0)
}
#endif
