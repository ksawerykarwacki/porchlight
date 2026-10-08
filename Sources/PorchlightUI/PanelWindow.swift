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

    final class ObserverView: NSView {
        var onClose: (() -> Void)?
        /// The top edge where the system last placed the window.
        private(set) var top: CGFloat?
        /// True while this view moves the window itself, so that move is not taken for the system's.
        private var isPinning = false
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers = []
            guard let window else { return }
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
