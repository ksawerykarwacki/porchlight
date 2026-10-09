import Foundation
import ServiceManagement

/// Whether Porchlight opens at login, and switching that on and off. The system only does this
/// for an app bundle, so a bare executable (tests, `swift run`) reports "cannot tell".
public struct LoginItem: Sendable {
    /// True, false, or nil when this copy cannot be a login item.
    public var isEnabled: @Sendable () -> Bool?
    /// Switches it. Returns nil when it worked, or why it did not, in words for the user.
    public var set: @Sendable (Bool) -> String?

    public init(isEnabled: @escaping @Sendable () -> Bool?, set: @escaping @Sendable (Bool) -> String?) {
        self.isEnabled = isEnabled
        self.set = set
    }

    /// For tests and bare executables: nothing to ask the system.
    public static let unavailable = LoginItem(isEnabled: { nil }, set: { _ in "This copy of Porchlight is not an app, so it cannot open at login." })

    public static func live(isBundled: Bool = Bundle.main.bundleURL.pathExtension == "app") -> LoginItem {
        guard isBundled else { return .unavailable }
        return LoginItem(
            isEnabled: { SMAppService.mainApp.status == .enabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    return "macOS did not change it: \(error.localizedDescription)"
                }
                // Registered but switched off by the user or by policy: say where to allow it.
                if enable, SMAppService.mainApp.status == .requiresApproval {
                    return "Allow Porchlight under System Settings > General > Login Items."
                }
                return nil
            })
    }
}
