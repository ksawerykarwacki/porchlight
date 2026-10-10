import AppKit
import Foundation
import PorchlightCore

/// Starts the freshly installed copy after a Homebrew upgrade and ends this one.
public enum AppRestart {
    /// What to run to bring the new copy up. When Homebrew's service runs the app, the service
    /// is restarted, so that launchd keeps owning it; otherwise the new bundle is simply opened.
    public static func command(serviceIsLoaded: Bool, brew: String?, prefix: String = "/opt/homebrew") -> [String] {
        if serviceIsLoaded, let brew {
            return [brew, "services", "restart", AppVersion.formula]
        }
        // A moment's wait, so this copy has quit before the new one looks for another instance.
        return ["/bin/sh", "-c", "sleep 1; /usr/bin/open -n \"$0\"", "\(prefix)/opt/porchlight/Porchlight.app"]
    }

    /// Whether launchd has Homebrew's service for Porchlight loaded for this user.
    public static func serviceIsLoaded() -> Bool {
        AppVersion.serviceLabels.contains { label in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["print", "gui/\(getuid())/\(label)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }

    /// Where each running copy of the app is, with links resolved: Homebrew keeps every build in
    /// a folder named after its commit, so the path says which build is running.
    public static func runningCopyPaths(bundleIdentifier: String = "io.github.ksawerykarwacki.porchlight") -> [String] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).compactMap { $0.bundleURL?.resolvingSymlinksInPath().path }
    }

    /// Asks every running copy of the app to quit and waits for them to be gone. For starting a
    /// new copy from outside the app: two copies would share a menu bar, and the second would
    /// not listen for the companion mod. True when none is left.
    @discardableResult
    public static func quitRunningCopies(bundleIdentifier: String = "io.github.ksawerykarwacki.porchlight", wait: TimeInterval = 8) -> Bool {
        func running() -> [NSRunningApplication] { NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) }
        let deadline = Date().addingTimeInterval(wait)
        // Asked again while any is left: launchd may bring the service's copy straight back.
        while !running().isEmpty, Date() < deadline {
            running().forEach { $0.terminate() }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return running().isEmpty
    }

    /// Runs a command in a session of its own and does not wait for it. Restarting the service
    /// ends this app; a child in the app's own process group would be taken down with it.
    @discardableResult
    public static func spawnDetached(_ arguments: [String]) -> Bool {
        guard let executable = arguments.first else { return false }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, nil, &attributes, argv, environ) == 0
    }

    /// Brings up the new copy and quits.
    @MainActor
    public static func relaunch() {
        let brew = AppVersion.brew()
        let prefix = brew.map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path } ?? "/opt/homebrew"
        let loaded = serviceIsLoaded()
        spawnDetached(command(serviceIsLoaded: loaded, brew: brew, prefix: prefix))
        // The service restart ends this process itself; without the service, quit to make room.
        if !loaded { NSApp?.terminate(nil) }
    }
}
