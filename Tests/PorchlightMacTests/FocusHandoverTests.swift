import AppKit
import Foundation
import Testing

@testable import PorchlightCore
@testable import PorchlightMac
@testable import PorchlightUI

/// Whether the terminal ends up with the keyboard can only be seen on a screen. These tests cover
/// what can be decided without one: that the hand-over is asked for, in the right order.
@MainActor
@Suite struct FocusHandoverTests {
    final class Paths: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var values: [String] { lock.withLock { stored } }
        func add(_ path: String) { lock.withLock { stored.append(path) } }
    }

    @Test func bringingATerminalForwardAlsoHandsItTheKeyboard() async {
        let activated = Paths()
        var launcher = MacTerminalLauncher()
        launcher.activate = { activated.add($0) }
        // Opening an app that is not there fails quietly; the hand-over is still asked for, since
        // opening does nothing either when the app is already in front.
        await launcher.bringForward("/nonexistent/Terminal.app")
        #expect(activated.values == ["/nonexistent/Terminal.app"])
    }

    @Test func activatingAnAppThatIsNotRunningDoesNothing() {
        MacTerminalLauncher.activateApp(atPath: "/nonexistent/Nothing.app")
    }

    @Test func theFocusReportNamesWhoIsInFrontAndWhetherThePanelHasTheKeyboard() {
        let report = PanelWindowObserver.focusReport()
        for field in ["front=", "porchlightActive=", "panelKey=", "panelVisible="] {
            #expect(report.contains(field), "\(field) missing from \(report)")
        }
    }

    @Test func closingThePanelToLetGoHidesIt() {
        let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(PanelWindowObserver.ObserverView())
        window.orderFront(nil)
        PanelWindowObserver.closePanelAndLetGo()
        #expect(!window.isVisible)
        #expect(PanelWindowObserver.focusReport().contains("panelVisible=false"))
    }
}
