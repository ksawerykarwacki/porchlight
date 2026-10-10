import Foundation

/// What `porchlight update` does: the app from Homebrew, then the Porchlight mods that are
/// installed in Claude Code. Only the plan is here; the command runs it.
public enum SelfUpdate {
    /// The name the mods' marketplace has in Claude Code.
    public static let marketplace = "porchlight"

    public struct Step: Sendable, Equatable {
        /// What is being done, for the person watching.
        public let title: String
        public let arguments: [String]
        /// How long it may take. Building the app takes minutes.
        public let timeout: TimeInterval

        public init(title: String, arguments: [String], timeout: TimeInterval = 120) {
            self.title = title
            self.arguments = arguments
            self.timeout = timeout
        }
    }

    /// The Porchlight mods in what `claude plugin list --json` printed: the ones installed from
    /// its marketplace, by name. Anything that is not that list gives none.
    public static func installedMods(pluginList: String) -> [String] {
        guard let rows = try? JSONSerialization.jsonObject(with: Data(pluginList.utf8)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, id.hasSuffix("@\(marketplace)") else { return nil }
            let name = String(id.dropLast(marketplace.count + 1))
            return name.isEmpty ? nil : name
        }.sorted()
    }

    /// Whether the app has to be started again after an upgrade: what is installed now is not
    /// what was, or what is running is not what is installed (an upgrade made earlier and never
    /// started). With no copy running there is nothing to replace, and none is started.
    public static func needsRestart(installedBefore: String, installedNow: String, running: [String]) -> Bool {
        guard !running.isEmpty else { return false }
        return installedBefore != installedNow || running.contains { !$0.hasPrefix(installedNow) }
    }

    /// Builds the app from the latest source. Homebrew does nothing when it is already there.
    public static func upgrade(brew: String) -> Step {
        Step(title: "Building the latest Porchlight with Homebrew (this takes a few minutes)", arguments: [brew, "upgrade", "--fetch-HEAD", AppVersion.formula], timeout: 20 * 60)
    }

    /// Brings the mods' listing up to date and then each installed mod. Running sessions keep
    /// the mod they loaded until they reload their plugins; that is theirs to do.
    public static func modSteps(claude: String, installed: [String]) -> [Step] {
        guard !installed.isEmpty else { return [] }
        return [Step(title: "Asking for the latest mods", arguments: [claude, "plugin", "marketplace", "update", marketplace])]
            + installed.map { Step(title: "Updating \($0)", arguments: [claude, "plugin", "update", "\($0)@\(marketplace)"]) }
    }
}
