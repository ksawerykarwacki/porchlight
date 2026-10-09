import Carbon.HIToolbox
import Foundation
import Testing

@testable import PorchlightCore
@testable import PorchlightMac
@testable import PorchlightUI

@MainActor
@Suite struct HotkeyTests {
    @Test func isShownTheWayMacOSWritesShortcuts() {
        #expect(Hotkey(keyCode: 49, modifiers: [.control, .option]).display == "⌃⌥Space")
        #expect(Hotkey(keyCode: 45, modifiers: [.command, .shift], character: "n").display == "⇧⌘N")
        // Every modifier, in the system's order, whatever order they were given in.
        #expect(Hotkey(keyCode: 36, modifiers: [.command, .shift, .option, .control]).display == "⌃⌥⇧⌘Return")
        #expect(Hotkey(keyCode: 97, modifiers: []).display == "F6")
        #expect(Hotkey(keyCode: 126, modifiers: [.command]).display == "⌘↑")
        // A key with no name and no recorded character still says something.
        #expect(Hotkey(keyCode: 10, modifiers: [.command]).display == "⌘Key 10")
    }

    @Test func aKeyAloneOrWithOnlyShiftIsNotAShortcut() {
        #expect(!Hotkey(keyCode: 45, modifiers: [], character: "n").isUsable)
        #expect(!Hotkey(keyCode: 45, modifiers: [.shift], character: "N").isUsable)
        #expect(Hotkey(keyCode: 45, modifiers: [.control], character: "n").isUsable)
        #expect(Hotkey(keyCode: 45, modifiers: [.option], character: "n").isUsable)
        #expect(Hotkey(keyCode: 45, modifiers: [.command], character: "n").isUsable)
        // Function keys type nothing, so they may stand alone.
        #expect(Hotkey(keyCode: 122, modifiers: []).isUsable)
        #expect(!Hotkey(keyCode: 400, modifiers: [.command]).isUsable)
    }

    @Test func isStoredInSettingsWithReadableModifiers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-hotkey-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = Settings.fileURL(in: directory)
        var settings = Settings(terminal: "warp")
        settings.hotkey = Hotkey(keyCode: 49, modifiers: [.option, .control])
        try settings.save(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"control\"") && text.contains("\"option\"") && text.contains("\"keyCode\" : 49"))
        #expect(Settings.load(from: url) == settings)
    }

    @Test func anUnusableOrOddShortcutInTheFileIsIgnoredWithoutLosingTheRest() throws {
        func load(_ json: String) throws -> Settings { try JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }
        let noModifier = try load(#"{"terminal": "warp", "hotkey": {"keyCode": 45, "modifiers": []}}"#)
        #expect(noModifier.hotkey == nil && noModifier.terminal == "warp")
        #expect(try load(#"{"hotkey": {"keyCode": 45, "modifiers": ["shift"]}}"#).hotkey == nil)
        #expect(try load(#"{"hotkey": "cmd-space"}"#).hotkey == nil)
        #expect(try load(#"{"hotkey": {"keyCode": 45}}"#).hotkey == nil)
        // Unknown modifier names are dropped; the known one keeps it usable.
        #expect(try load(#"{"hotkey": {"keyCode": 45, "modifiers": ["hyper", "command"], "character": "n"}}"#).hotkey == Hotkey(keyCode: 45, modifiers: [.command], character: "n"))
    }

    @Test func modifiersTranslateToWhatTheSystemRegisters() {
        #expect(Hotkey(keyCode: 49, modifiers: [.control, .option]).carbonModifiers == UInt32(controlKey | optionKey))
        #expect(Hotkey(keyCode: 49, modifiers: [.command, .shift]).carbonModifiers == UInt32(cmdKey | shiftKey))
        #expect(Hotkey(keyCode: 97, modifiers: []).carbonModifiers == 0)
    }

    func model() throws -> (InboxModel, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-hotkey-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Settings.fileURL(in: directory)
        return (InboxModel(settingsURL: url, remindersURL: ReminderState.fileURL(in: directory)), url)
    }

    @Test func aNewShortcutIsRegisteredSavedAndAnnounced() throws {
        let (model, url) = try model()
        var registered: [Hotkey?] = []
        model.registerHotkey = { registered.append($0); return true }
        let shortcut = Hotkey(keyCode: 49, modifiers: [.control, .option])
        model.setHotkey(shortcut)
        #expect(registered == [shortcut])
        #expect(model.hotkey == shortcut && Settings.load(from: url).hotkey == shortcut)
        #expect(model.notice == "⌃⌥Space opens a new session from any app")
        // The same again does nothing.
        model.setHotkey(shortcut)
        #expect(registered.count == 1)

        model.setHotkey(nil)
        #expect(registered == [shortcut, nil])
        #expect(model.hotkey == nil && Settings.load(from: url).hotkey == nil)
        #expect(model.notice == "Shortcut removed")
    }

    @Test func aShortcutTheSystemRefusesIsNotSavedAndTheOldOneIsPutBack() throws {
        let (model, url) = try model()
        let old = Hotkey(keyCode: 49, modifiers: [.control, .option])
        let taken = Hotkey(keyCode: 49, modifiers: [.command])
        var registered: [Hotkey?] = []
        model.registerHotkey = { registered.append($0); return $0 != taken }
        model.setHotkey(old)
        model.setHotkey(taken)
        #expect(registered == [old, taken, old])
        #expect(model.hotkey == old && Settings.load(from: url).hotkey == old)
        #expect(model.notice == "⌘Space is already used by another app")
    }

    @Test func theSuggestedShortcutIsOnlyRegisteredWhenAskedFor() throws {
        #expect(Hotkey.suggested.display == "⌃⌥⌘N")
        #expect(Hotkey.suggested.isUsable)
        #expect(Hotkey.suggested.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))

        // A fresh model has no shortcut and registers nothing at launch.
        let (model, url) = try model()
        var registered: [Hotkey?] = []
        model.registerHotkey = { registered.append($0); return true }
        model.registerSavedHotkey()
        #expect(model.hotkey == nil && registered.isEmpty)

        // What the "Use ⌃⌥⌘N" button does.
        var actions = InboxActions()
        actions.setHotkey = { model.setHotkey($0) }
        actions.setHotkey(.suggested)
        #expect(registered == [Hotkey.suggested])
        #expect(Settings.load(from: url).hotkey == .suggested)
        #expect(model.notice == "⌃⌥⌘N opens a new session from any app")
    }

    @Test func theSavedShortcutIsRegisteredAtLaunch() throws {
        let (first, url) = try model()
        let shortcut = Hotkey(keyCode: 45, modifiers: [.command, .shift], character: "n")
        first.setHotkey(shortcut)

        let relaunched = InboxModel(settingsURL: url, remindersURL: ReminderState.fileURL(in: url.deletingLastPathComponent()))
        var registered: [Hotkey?] = []
        relaunched.registerHotkey = { registered.append($0); return false }
        relaunched.registerSavedHotkey()
        #expect(registered == [shortcut])
        // Taken in the meantime: it says so, and keeps the setting for next time.
        #expect(relaunched.notice == "⇧⌘N is already used by another app")
        #expect(relaunched.hotkey == shortcut)
    }

    @Test func theRecorderShowsTheShortcutOrAnInvitation() {
        typealias Button = HotkeyRecorder.RecorderButton
        #expect(Button.title(for: nil, recording: false) == "Record a shortcut")
        #expect(Button.title(for: Hotkey(keyCode: 49, modifiers: [.option]), recording: false) == "⌥Space")
        #expect(Button.title(for: Hotkey(keyCode: 49, modifiers: [.option]), recording: true) == "Type a shortcut…")
        let button = Button()
        #expect(button.title == "Record a shortcut")
        button.hotkey = Hotkey(keyCode: 97, modifiers: [])
        #expect(button.title == "F6")
    }
}
