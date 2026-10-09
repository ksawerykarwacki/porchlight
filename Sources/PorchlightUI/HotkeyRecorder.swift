import AppKit
import PorchlightCore
import PorchlightMac
import SwiftUI

/// A button that shows the shortcut and, once clicked, takes the next key press as the new one.
/// Escape leaves it as it was; Delete removes it.
struct HotkeyRecorder: NSViewRepresentable {
    let hotkey: Hotkey?
    let onChange: (Hotkey?) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        let button = RecorderButton()
        button.hotkey = hotkey
        button.onChange = onChange
        return button
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.onChange = onChange
        if button.hotkey != hotkey { button.hotkey = hotkey }
    }

    final class RecorderButton: NSButton {
        var hotkey: Hotkey? { didSet { refresh() } }
        var onChange: ((Hotkey?) -> Void)?
        private var monitor: Any?
        private var isRecording: Bool { monitor != nil }

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            controlSize = .small
            font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            target = self
            action = #selector(toggle)
            refresh()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        static func title(for hotkey: Hotkey?, recording: Bool) -> String {
            if recording { return "Type a shortcut…" }
            return hotkey?.display ?? "Record a shortcut"
        }

        private func refresh() {
            title = Self.title(for: hotkey, recording: isRecording)
        }

        @objc private func toggle() {
            if isRecording { stop() } else { start() }
        }

        private func start() {
            // Only while recording, and only this app's own key presses: the monitor sees what
            // is typed into Porchlight's panel, nothing else.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.take(event)
                return nil
            }
            refresh()
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            refresh()
        }

        private func take(_ event: NSEvent) {
            let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            if plain, event.keyCode == 53 {
                stop()
            } else if plain, event.keyCode == 51 {
                stop()
                onChange?(nil)
            } else if let recorded = Hotkey(event: event) {
                stop()
                onChange?(recorded)
            } else {
                // A key on its own would take that key away from every app.
                NSSound.beep()
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() }
        }
    }
}
