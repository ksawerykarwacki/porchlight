import AppKit
import Foundation

/// Messages from the `porchlight` tool to the running app. They carry no data: a signal only says
/// "do the thing the user just asked for".
public enum AppSignal: String, Sendable {
    /// Show the palette that starts a new session.
    case newSession = "new-session"

    public static let bundleIdentifier = "io.github.ksawerykarwacki.porchlight"

    var name: Notification.Name { Notification.Name("\(Self.bundleIdentifier).\(rawValue)") }

    /// Whether the app is running, and so whether anyone will hear a signal.
    public static var isAppRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    public func post() {
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Calls `handler` on the main actor each time the signal arrives, for as long as the app runs.
    @MainActor
    public static func observe(_ signal: AppSignal, handler: @escaping @MainActor () -> Void) {
        // Kept for the life of the process: the app listens until it quits.
        _ = DistributedNotificationCenter.default().addObserver(forName: signal.name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
