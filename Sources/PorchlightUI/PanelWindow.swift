import AppKit
import SwiftUI

/// Where the panel's window should sit after its content changed height.
///
/// AppKit resizes a window from its bottom-left corner, so a panel that gets shorter (switching
/// to a shorter tab, a session finishing) would drop away from the menu bar. Keeping the top edge
/// where it was when the panel opened keeps it attached.
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

/// Watches the panel's window: keeps its top edge fixed while it is open, and reports when it
/// closes. Put it in the background of the panel's content.
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
        /// The top edge the window had when it opened; nil while it is closed.
        private var top: CGFloat?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let center = NotificationCenter.default
            observers.forEach(center.removeObserver)
            observers = []
            guard let window else { return }

            func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (NSWindow) -> Void) {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated {
                        if let window { handler(window) }
                    }
                })
            }

            observe(NSWindow.didBecomeKeyNotification) { [weak self] window in
                // The system has just placed the panel under the menu bar: remember where.
                self?.top = window.frame.maxY
            }
            observe(NSWindow.didResizeNotification) { [weak self] window in
                guard let top = self?.top, window.isVisible, PanelPinning.needsPinning(window.frame, top: top) else { return }
                window.setFrame(PanelPinning.pinned(window.frame, top: top), display: true)
            }
            observe(NSWindow.didResignKeyNotification) { [weak self] window in
                // The panel hides just after it loses focus; look once that has happened.
                DispatchQueue.main.async {
                    guard !window.isVisible else { return }
                    self?.top = nil
                    self?.onClose?()
                }
            }
        }
        // No deinit clean-up is needed: the view leaves its window before it goes away, which
        // runs `viewDidMoveToWindow` with no window and removes the observers.
    }
}
