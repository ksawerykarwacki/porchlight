import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightMac
@testable import PorchlightUI

@MainActor
@Suite struct TimeSensitiveSettingsTests {
    let fourHours: TimeInterval = 4 * 3600

    func decode(_ json: String) throws -> ReminderSettings {
        try JSONDecoder().decode(ReminderSettings.self, from: Data(json.utf8))
    }

    func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-time-sensitive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func missingMeansOffAndAChosenTimeIsRead() throws {
        #expect(try decode("{}").timeSensitiveAfter == nil)
        #expect(try decode(#"{"timeSensitiveAfter":14400}"#).timeSensitiveAfter == fourHours)
        #expect(try decode(#"{"timeSensitiveAfter":null}"#).timeSensitiveAfter == nil)
        // A file from before the setting existed keeps everything it had.
        let older = try decode(#"{"ladder":[300,3600],"repeatEvery":7200,"soundAfter":3600,"digestMinute":480,"hideDetails":true}"#)
        #expect(older.timeSensitiveAfter == nil)
        #expect(older == ReminderSettings(ladder: [300, 3600], repeatEvery: 7200, soundAfter: 3600, digestMinute: 480, hideDetails: true))
    }

    @Test func anOddValueMeansOffAndTheOtherSettingsSurvive() throws {
        for odd in [#""soon""#, "true", "-5", "0", "[14400]", #"{"hours":4}"#] {
            let settings = try decode(#"{"ladder":[300,3600],"timeSensitiveAfter":\#(odd),"repeatEvery":null,"hideDetails":true}"#)
            #expect(settings.timeSensitiveAfter == nil, "\(odd) should mean off")
            #expect(settings.ladder == [300, 3600])
            #expect(settings.repeatEvery == nil)
            #expect(settings.hideDetails)
        }
        // And the other way round: odd neighbours do not take a good value with them.
        let mixed = try decode(#"{"ladder":"soon","soundAfter":true,"timeSensitiveAfter":7200}"#)
        #expect(mixed.timeSensitiveAfter == 7200)
        #expect(mixed.ladder == ReminderSettings().ladder)
    }

    @Test func offAndOnBothSurviveASaveAndALoad() throws {
        let on = ReminderSettings(timeSensitiveAfter: fourHours)
        let onData = try JSONEncoder().encode(on)
        #expect(try JSONDecoder().decode(ReminderSettings.self, from: onData) == on)
        #expect(String(decoding: onData, as: UTF8.self).contains(#""timeSensitiveAfter":14400"#))

        // Off is written down as off, not left out.
        let offData = try JSONEncoder().encode(ReminderSettings())
        #expect(String(decoding: offData, as: UTF8.self).contains(#""timeSensitiveAfter":null"#))
        #expect(try JSONDecoder().decode(ReminderSettings.self, from: offData).timeSensitiveAfter == nil)
    }

    @Test func aChoiceInTheAppIsSavedToSettingsJSONAlongsideTheRest() throws {
        let directory = try scratch()
        let url = Settings.fileURL(in: directory)
        #expect(url.path.hasPrefix(directory.path))
        try Settings(
            terminal: "ghostty", claudePath: "/custom/claude", preferAgentView: true,
            reminders: ReminderSettings(ladder: [300, 3600], repeatEvery: nil, hideDetails: true)
        ).save(to: url)
        let model = InboxModel(settingsURL: url, remindersURL: ReminderState.fileURL(in: directory))
        #expect(model.reminderSettings.timeSensitiveAfter == nil)

        model.updateReminders { $0.timeSensitiveAfter = self.fourHours }
        #expect(model.reminderSettings.timeSensitiveAfter == fourHours)

        // In the file itself, under "reminders".
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let reminders = try #require(object["reminders"] as? [String: Any])
        #expect(reminders["timeSensitiveAfter"] as? Double == fourHours)

        let saved = Settings.load(from: url)
        #expect(saved.reminders?.timeSensitiveAfter == fourHours)
        #expect(saved.terminal == "ghostty" && saved.claudePath == "/custom/claude" && saved.preferAgentView == true)
        #expect(saved.reminders?.ladder == [300, 3600])
        #expect(saved.reminders?.repeatEvery == nil)
        #expect(saved.reminders?.hideDetails == true)
        // A fresh model, as after a restart, reads it back.
        #expect(InboxModel(settingsURL: url, remindersURL: ReminderState.fileURL(in: directory)).reminderSettings.timeSensitiveAfter == fourHours)

        // Turning it off again is saved too.
        model.updateReminders { $0.timeSensitiveAfter = nil }
        #expect(Settings.load(from: url).reminders?.timeSensitiveAfter == nil)
        #expect(Settings.load(from: url).reminders?.ladder == [300, 3600])
    }

    @Test func anOddValueInSettingsJSONDoesNotCostTheOtherSettings() throws {
        let directory = try scratch()
        let url = Settings.fileURL(in: directory)
        try Data(#"{"terminal":"warp","reminders":{"timeSensitiveAfter":"always","ladder":[600,7200],"digestMinute":null}}"#.utf8).write(to: url)
        let loaded = Settings.load(from: url)
        #expect(loaded.terminal == "warp")
        #expect(loaded.reminders?.timeSensitiveAfter == nil)
        #expect(loaded.reminders?.ladder == [600, 7200])
        #expect(loaded.reminders?.digestMinute == nil)
    }

    @Test func theChoicesIncludeOffAndTheSuggestedFourHours() {
        #expect(ReminderOptions.timeSensitiveAfter.first == .some(nil))
        #expect(ReminderOptions.timeSensitiveAfter.contains(ReminderSettings().timeSensitiveAfter))
        #expect(ReminderOptions.timeSensitiveAfter.contains(fourHours))
        #expect(ReminderOptions.timeSensitiveAfter.count >= 4)
        // Every choice is one the settings accept as it is.
        for choice in ReminderOptions.timeSensitiveAfter {
            #expect(ReminderSettings(timeSensitiveAfter: choice).timeSensitiveAfter == choice)
        }
    }

    @Test func theSettingsPageShowsTheRowAndItsCurrentValue() throws {
        var off = InboxActions()
        off.showsSettings = true
        var on = off
        on.reminders.timeSensitiveAfter = fourHours

        let offPage = try render(SettingsPage(actions: off, drawsMenus: false, timeSensitive: .enabled))
        let onPage = try render(SettingsPage(actions: on, drawsMenus: false, timeSensitive: .enabled), named: "settings-time-sensitive")
        // Same page, one value drawn differently: "Off" against "4 hours".
        #expect(onPage.pixelsHigh == offPage.pixelsHigh && onPage.pixelsWide == offPage.pixelsWide)
        let changed = try differingRows(offPage, onPage)
        #expect(!changed.isEmpty)
        // Confined to one line of text (the page is drawn at twice its size).
        let span = (changed.max() ?? 0) - (changed.min() ?? 0)
        #expect(span < 40)

        // The same change of another setting lands on a different line, so the one above is the
        // time-sensitive row and not the page as a whole.
        var repeatOff = off
        repeatOff.reminders.repeatEvery = nil
        let other = try differingRows(offPage, try render(SettingsPage(actions: repeatOff, drawsMenus: false, timeSensitive: .enabled)))
        // And nothing at all differs between two renders of the same page.
        #expect(try differingRows(offPage, try render(SettingsPage(actions: off, drawsMenus: false, timeSensitive: .enabled))).isEmpty)
        #expect(!other.isEmpty && (other.max() ?? 0) < (changed.min() ?? 0))

        // The whole panel shows it as well.
        let panelOff = try render(InboxView(snapshot: StoreSnapshot(), actions: off, scrolls: false))
        let panelOn = try render(InboxView(snapshot: StoreSnapshot(), actions: on, scrolls: false))
        #expect(!(try differingRows(panelOff, panelOn)).isEmpty)
    }

    @Test func theSettingsPageSaysWhenMacOSWillNotHonourTheChoice() throws {
        var off = InboxActions()
        off.showsSettings = true
        var on = off
        on.reminders.timeSensitiveAfter = fourHours
        func height(_ actions: InboxActions, _ support: TimeSensitiveSupport) throws -> Int {
            try render(SettingsPage(actions: actions, drawsMenus: false, timeSensitive: support)).pixelsHigh
        }

        let plain = try height(on, .enabled)
        // A note of at least one line of small text appears under the row.
        #expect(try height(on, .notSupported) >= plain + 24)
        #expect(try height(on, .disabled) >= plain + 24)
        #expect(try height(on, .unknown) == plain)
        // Nothing is said while the setting is off: there is nothing that will not work.
        #expect(try height(off, .notSupported) == plain)

        try render(SettingsPage(actions: on, drawsMenus: false, timeSensitive: .notSupported), named: "settings-time-sensitive-unsigned")
    }

    /// The pixel rows in which two renderings of the same size visibly differ.
    ///
    /// Not byte for byte: the first renders of a process draw the same text one level (of 255)
    /// lighter or darker in some pixels than later renders do, so which test happens to render
    /// first would decide the result. A changed word moves pixels by a hundred levels or more;
    /// anything up to `tolerance` is the same picture.
    func differingRows(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, tolerance: Int = 16) throws -> [Int] {
        try #require(a.pixelsHigh == b.pixelsHigh && a.bytesPerRow == b.bytesPerRow)
        let first = try #require(a.bitmapData)
        let second = try #require(b.bitmapData)
        return (0..<a.pixelsHigh).filter { row in
            let start = row * a.bytesPerRow
            return (start..<start + a.bytesPerRow).contains { abs(Int(first[$0]) - Int(second[$0])) > tolerance }
        }
    }

    @discardableResult
    func render(_ view: some View, named name: String? = nil) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: 400).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        if let name, let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return bitmap
    }
}
