import Foundation
import Observation
import PorchlightCore

/// The Update section of the Settings tab: what is installed, whether something newer exists,
/// and installing it.
@MainActor
@Observable
public final class UpdateModel {
    public enum State: Equatable {
        /// Not a Homebrew install: there is nothing this button could update.
        case unavailable
        case unknown
        case checking
        case upToDate
        case available(latest: String)
        case updating
        case restarting
        case failed(String)
    }

    /// The short commit Homebrew installed, read once at launch; nil when not a Homebrew install.
    public let installed: String?
    public private(set) var state: State
    private let updater: AppUpdater
    /// Starts the new copy and ends this one. Set by the app.
    public var restart: () -> Void = {}

    public init(bundlePath: String = Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/", updater: AppUpdater = AppUpdater()) {
        self.installed = AppVersion.installedCommit(bundlePath: bundlePath)
        self.updater = updater
        self.state = installed == nil ? .unavailable : .unknown
    }

    public var canUpdate: Bool {
        if case .available = state { return true }
        return false
    }

    /// One line for the Settings tab.
    public var summary: String {
        switch state {
        case .unavailable: "Not installed with Homebrew, so updates are off."
        case .unknown: "Installed: \(installed ?? "")"
        case .checking: "Checking for a newer version…"
        case .upToDate: "Up to date (\(installed ?? ""))."
        case .available(let latest): "A newer version is available: \(latest.prefix(7)) (installed: \(installed ?? ""))."
        case .updating: "Updating. Homebrew is building the new version; this takes a few minutes."
        case .restarting: "Restarting…"
        case .failed(let message): message
        }
    }

    /// Asks what `main` is. Does nothing while a check or an update is already running.
    public func check() async {
        guard let installed else { return }
        switch state {
        case .checking, .updating, .restarting: return
        default: break
        }
        state = .checking
        do {
            let latest = try await updater.latestCommit()
            state = AppVersion.isNewer(latest: latest, installed: installed) ? .available(latest: latest) : .upToDate
        } catch AppUpdater.Failure.failed(let message) {
            state = .failed("Could not check for updates: \(message)")
        } catch {
            state = .failed("Could not check for updates.")
        }
    }

    /// Rebuilds with Homebrew and restarts into the new copy.
    public func update() async {
        guard installed != nil, canUpdate else { return }
        state = .updating
        do {
            try await updater.upgrade()
            state = .restarting
            restart()
        } catch AppUpdater.Failure.noHomebrew {
            state = .failed("Homebrew was not found at /opt/homebrew/bin/brew or /usr/local/bin/brew.")
        } catch AppUpdater.Failure.failed(let message) {
            state = .failed("The update did not finish. Homebrew said:\n\(message)")
        } catch {
            state = .failed("The update did not finish.")
        }
    }

    /// Checks now and then once an hour, for as long as the app runs.
    public func run() async {
        guard installed != nil else { return }
        while !Task.isCancelled {
            await check()
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
