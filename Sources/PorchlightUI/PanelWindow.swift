import AppKit
import SwiftUI

/// Where the panel's window should sit after its content changed height.
///
/// AppKit resizes a window from its bottom-left corner, so a panel that gets shorter (switching
/// to a shorter tab, a session finishing) would drop away from the menu bar. Keeping the top edge
/// where the system last put it keeps the panel attached.
public enum PanelPinning {
    /// The frame with the same size and left edge, moved so its top edge is at `top`.
    public static func pinned(_ frame: CGRect, top: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: top - frame.height, width: frame.width, height: frame.height)
    }

    /// Whether a frame has drifted from its top edge by more than a rounding error.
    public static func needsPinning(_ frame: CGRect, top: CGFloat) -> Bool {
        abs(frame.maxY - top) > 0.5
    }
}

/// Which pointer the panel shows. The panel opens over whatever app is in front and that app's
/// pointer stays: a text cursor over a terminal, sometimes replaced when a view happened to set
/// one. So the panel says which it wants at every move: the arrow, as for any menu, except over
/// a field that takes text.
public enum PanelPointer {
    @MainActor
    public static func takesText(_ view: NSView?) -> Bool {
        var current = view
        while let candidate = current {
            if candidate is NSTextView { return true }
            if let field = candidate as? NSTextField { return field.isEditable || field.isSelectable }
            current = candidate.superview
        }
        return false
    }
}

/// Watches the panel's window: keeps its top edge fixed when it changes height, and reports when
/// it closes. Put it in the background of the panel's content.
public struct PanelWindowObserver: NSViewRepresentable {
    let onClose: () -> Void

    public init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    public func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onClose = onClose
        return view
    }

    public func updateNSView(_ view: NSView, context: Context) {
        (view as? ObserverView)?.onClose = onClose
    }

    /// The menu-bar panel's window, while it exists.
    @MainActor private(set) static weak var panel: NSWindow?

    /// Closes the menu-bar panel, as clicking outside it would. For actions that put something
    /// else on screen, which the panel would otherwise sit on top of.
    @MainActor
    public static func closePanel() {
        panel?.close()
    }

    /// Closes the panel and gives up being the active app, so the keyboard goes back to the app
    /// the user was in. For actions that hand over to another app, such as a terminal.
    @MainActor
    public static func closePanelAndLetGo() {
        panel?.close()
        NSApp?.deactivate()
    }

    /// Who has the keyboard right now, for the activity log: a focus problem cannot be seen from
    /// inside the app, only reconstructed afterwards.
    @MainActor
    public static func focusReport() -> String {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "none"
        let active = NSApp?.isActive == true
        let panelKey = panel?.isKeyWindow == true
        let panelVisible = panel?.isVisible == true
        return "front=\(front) porchlightActive=\(active) panelKey=\(panelKey) panelVisible=\(panelVisible)"
    }

    final class ObserverView: NSView {
        var onClose: (() -> Void)?
        /// The top edge where the system last placed the window.
        private(set) var top: CGFloat?
        /// True while this view moves the window itself, so that move is not taken for the system's.
        private var isPinning = false
        private var observers: [NSObjectProtocol] = []

        private var pointerArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let pointerArea { removeTrackingArea(pointerArea) }
            // Always active: the panel is used while another app is the active one.
            let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate], owner: self)
            addTrackingArea(area)
            pointerArea = area
        }

        private func keepPointer(_ event: NSEvent) {
            guard let content = window?.contentView else { return }
            let under = content.hitTest(content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow)
            (PanelPointer.takesText(under) ? NSCursor.iBeam : NSCursor.arrow).set()
        }

        override func mouseEntered(with event: NSEvent) { keepPointer(event) }
        override func mouseMoved(with event: NSEvent) { keepPointer(event) }
        override func cursorUpdate(with event: NSEvent) { keepPointer(event) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers = []
            guard let window else { return }
            PanelWindowObserver.panel = window
            // If the window is already on screen, where it is now is where the system put it.
            if window.isVisible { top = window.frame.maxY }

            func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (NSWindow) -> Void) {
                observers.append(center.addObserver(forName: name, object: window, queue: nil) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { handler(window) }
                    }
                })
            }

            // Any move that is not ours is the system placing the panel under the menu bar.
            observe(NSWindow.didMoveNotification) { [weak self] window in
                guard let self, !self.isPinning else { return }
                self.top = window.frame.maxY
            }
            observe(NSWindow.didBecomeKeyNotification) { [weak self] window in
                guard let self, !self.isPinning else { return }
                self.top = window.frame.maxY
            }
            // A resize keeps the bottom-left corner, which moves the top: put it back.
            observe(NSWindow.didResizeNotification) { [weak self] window in
                self?.pin(window)
            }
            observe(NSWindow.didResignKeyNotification) { [weak self] window in
                // The panel hides just after it loses focus; look once that has happened.
                DispatchQueue.main.async {
                    guard !window.isVisible else { return }
                    self?.onClose?()
                }
            }
        }
        // No deinit clean-up is needed: the view leaves its window before it goes away, which
        // runs `viewDidMoveToWindow` with no window and removes the observers.

        private func pin(_ window: NSWindow) {
            guard !isPinning else { return }
            guard let top else {
                // Never placed while we were watching: take this frame as the starting point.
                self.top = window.frame.maxY
                return
            }
            guard PanelPinning.needsPinning(window.frame, top: top) else { return }
            isPinning = true
            window.setFrame(PanelPinning.pinned(window.frame, top: top), display: true)
            isPinning = false
        }
    }
}
