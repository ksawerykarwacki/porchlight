import AppKit
import PorchlightCore
import SwiftUI

/// The palette's window: floats over whatever app is in front and takes the keyboard without
/// making Porchlight the active app, so closing it leaves the user where they were.
final class PalettePanel: NSPanel {
    var onEscape: (() -> Void)?
    var onConfirm: (() -> Void)?
    /// ⌘Return and ⌘R when no view of its own took them: actions on the selected session.
    var onCommandReturn: (() -> Void)?
    var onCommandR: (() -> Void)?
    /// ⌘S and ⌘D: ask to stop or remove the selected session.
    var onCommandS: (() -> Void)?
    var onCommandD: (() -> Void)?
    /// ⌘P: pin or unpin the selected session.
    var onCommandP: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PaletteView.width + 2 * PaletteController.margin, height: 620),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The card brings its own shadow; the window is a larger, clear rectangle around it.
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    // A borderless window refuses the keyboard unless it says otherwise.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        // Return with no text field in focus: the result and failure steps.
        if event.keyCode == 36 || event.keyCode == 76 {
            onConfirm?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// Porchlight has no menu bar of its own, and the editing shortcuts live in the Edit menu.
    /// Without this, ⌘V and friends do nothing in the palette's fields.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        guard event.type == .keyDown else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            onCommandReturn?()
            return true
        }
        if modifiers == .command, let key = event.charactersIgnoringModifiers?.lowercased(), let action = ["r": onCommandR, "s": onCommandS, "d": onCommandD, "p": onCommandP][key] {
            action?()
            return true
        }
        let action: Selector? =
            switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
            case (.command, "v"): #selector(NSText.paste(_:))
            case (.command, "c"): #selector(NSText.copy(_:))
            case (.command, "x"): #selector(NSText.cut(_:))
            case (.command, "a"): #selector(NSResponder.selectAll(_:))
            case (.command, "z"): Selector(("undo:"))
            case ([.command, .shift], "z"): Selector(("redo:"))
            default: nil
            }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// Shows and hides the palette, and runs what its buttons need from AppKit.
@MainActor
public final class PaletteController {
    static let margin: CGFloat = 40

    public let model: PaletteModel
    private let hover = HoverTracker()
    private var panel: PalettePanel?
    private var resignObserver: NSObjectProtocol?
    /// True while a system folder dialog is up, which takes the keyboard without the palette
    /// being done.
    private var isChoosingFolder = false

    public init(model: PaletteModel) {
        self.model = model
        model.onClose = { [weak self] in self?.hide() }
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    public func toggle() {
        if isVisible { hide() } else { show() }
    }

    public func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        Task { await model.begin() }
        place(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel()
        panel.onEscape = { [weak self] in self?.model.escape() }
        panel.onConfirm = { [weak self] in self?.model.confirm() }
        panel.onCommandReturn = { [weak self] in self?.model.copyReplyAndOpenSelected() }
        panel.onCommandR = { [weak self] in self?.model.retrySelected() }
        panel.onCommandS = { [weak self] in self?.model.askControlSelected(.stop) }
        panel.onCommandD = { [weak self] in self?.model.askControlSelected(.remove) }
        panel.onCommandP = { [weak self] in Task { await self?.model.togglePinSelected() } }
        let content = PaletteView(
            model: model, hover: hover, browse: { [weak self] in self?.chooseFolder(asRoot: false) },
            addRoot: { [weak self] in self?.chooseFolder(asRoot: true) }
        )
        // Room for the card's shadow, which the window would otherwise cut off.
        .padding(Self.margin)
        // The window keeps one size; the card grows downwards from its top inside it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        panel.contentView = NSHostingView(rootView: content)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isChoosingFolder else { return }
                self.hide()
            }
        }
        return panel
    }

    /// Upper middle of the screen the pointer is on, where the eye already is.
    private func place(_ panel: NSPanel) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let top = visible.maxY - visible.height * 0.16 + Self.margin
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: top - size.height))
    }

    private func chooseFolder(asRoot: Bool) {
        let dialog = NSOpenPanel()
        dialog.canChooseDirectories = true
        dialog.canChooseFiles = false
        dialog.allowsMultipleSelection = false
        dialog.prompt = asRoot ? "Search This Folder" : "Start Here"
        dialog.message = asRoot ? "Choose the folder your repositories live in." : "Choose the folder to start the session in."
        isChoosingFolder = true
        // A system dialog needs an active app behind it.
        NSApp.activate(ignoringOtherApps: true)
        let response = dialog.runModal()
        isChoosingFolder = false
        panel?.makeKeyAndOrderFront(nil)
        guard response == .OK, let url = dialog.url else { return }
        if asRoot {
            model.addRoot(path: url.path)
        } else {
            model.chooseFolder(path: url.path)
        }
    }
}

/// A one-line text field backed by AppKit, so that arrow keys, Return and Escape can be told
/// apart from typing and the keyboard can be handed to it on request.
struct PaletteTextField: NSViewRepresentable {
    let text: String
    let placeholder: String
    let fontSize: CGFloat
    /// A value that changes when this field should take the keyboard; nil if it never asks.
    let focusRequest: Int?
    let onChange: (String) -> Void
    var onMove: (Int) -> Void = { _ in }
    var onSubmit: () -> Void = {}
    /// Option-Return.
    var onAlternateSubmit: () -> Void = {}
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if let focusRequest, focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            // The field may not be in its window yet on the first pass.
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaletteTextField
        var lastFocusRequest: Int?

        init(_ parent: PaletteTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.onChange(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): parent.onAlternateSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

/// The prompt: several lines, where Return is a new line and ⌘Return starts the session.
struct PalettePromptField: NSViewRepresentable {
    let text: String
    let focusRequest: Int
    let onChange: (String) -> Void
    /// The flag is true when the session should be opened as well (⇧⌘Return).
    let onSubmit: (Bool) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        textView.string = text

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PromptTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        if textView.string != text { textView.string = text }
        if focusRequest != context.coordinator.lastFocusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PalettePromptField
        var lastFocusRequest: Int?

        init(_ parent: PalettePromptField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onChange(textView.string)
        }
    }
}

final class PromptTextView: NSTextView {
    var onSubmit: ((Bool) -> Void)?
    var onCancel: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76, event.modifierFlags.contains(.command) {
            onSubmit?(event.modifierFlags.contains(.shift))
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
