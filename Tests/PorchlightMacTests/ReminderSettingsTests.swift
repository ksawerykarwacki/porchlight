import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

/// Holds a value a `@Sendable` closure can read and a test can change.
final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

actor CollectingDelivery: ReminderDelivery {
    private(set) var ids: [String] = []
    func deliver(_ reminder: Reminder) { ids.append(reminder.id) }
    func withdraw(reminderIDs: [String]) {}
}

@MainActor
@Suite struct ReminderSettingsTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func decode(_ json: String) throws -> ReminderSettings {
        try JSONDecoder().decode(ReminderSettings.self, from: Data(json.utf8))
    }

    func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func missingValuesAreDefaultsAndOffStaysOff() throws {
        #expect(try decode("{}") == ReminderSettings())

        let custom = try decode(#"{"ladder":[120,60],"repeatEvery":null,"digestMinute":null,"hideDetails":true,"quietHours":{"startMinute":1320,"endMinute":420}}"#)
        #expect(custom.ladder == [60, 120])
        #expect(custom.repeatEvery == nil)
        #expect(custom.digestMinute == nil)
        #expect(custom.hideDetails)
        #expect(custom.quietHours == QuietHours(startMinute: 1320, endMinute: 420))

        // "Off" survives a save and a load; it does not turn back into the default.
        let again = try JSONDecoder().decode(ReminderSettings.self, from: JSONEncoder().encode(custom))
        #expect(again == custom)
    }

    @Test func oddValuesFallBackOneByOne() throws {
        let odd = try decode(#"{"ladder":"soon","repeatEvery":"often","soundAfter":true,"digestMinute":99999,"hideDetails":"yes","quietHours":7,"future":1}"#)
        // Every bad value became its default; nothing threw.
        #expect(odd == ReminderSettings())

        let mixed = try decode(#"{"ladder":"soon","hideDetails":true}"#)
        #expect(mixed.ladder == ReminderSettings().ladder)
        #expect(mixed.hideDetails)

        // One odd entry in the settings file does not discard the others.
        let directory = try scratch()
        let url = Settings.fileURL(in: directory)
        try Data(#"{"terminal":"ghostty","preferAgentView":"maybe","reminders":{"ladder":[300,3600]}}"#.utf8).write(to: url)
        let loaded = Settings.load(from: url)
        #expect(loaded.terminal == "ghostty")
        #expect(loaded.preferAgentView == nil)
        #expect(loaded.reminders?.ladder == [300, 3600])
    }

    @Test func theSecondStepAlwaysComesAfterTheFirstAndCarriesTheSound() {
        var settings = ReminderSettings()
        settings.setSteps(first: 1800, second: 4 * 3600)
        #expect(settings.ladder == [1800, 4 * 3600])
        #expect(settings.soundAfter == 4 * 3600)
        #expect(settings.firstStep == 1800 && settings.secondStep == 4 * 3600)

        // Raising the first step past the second pushes the second out.
        settings.setSteps(first: 3600, second: 3600)
        #expect(settings.ladder == [3600, 7200])
        #expect(settings.soundAfter == 7200)

        #expect(ReminderOptions.duration(300) == "5 minutes")
        #expect(ReminderOptions.duration(60) == "1 minute")
        #expect(ReminderOptions.duration(3600) == "1 hour")
        #expect(ReminderOptions.duration(8 * 3600) == "8 hours")
        #expect(ReminderOptions.duration(5400) == "1 h 30 min")
        #expect(ReminderOptions.hour(9) == "09:00")
        #expect(ReminderOptions.firstSteps.contains(ReminderSettings().firstStep))
        #expect(ReminderOptions.secondSteps.contains(ReminderSettings().secondStep))
        #expect(ReminderOptions.repeats.contains(ReminderSettings().repeatEvery))
    }

    @Test func aChangeInTheAppIsSavedAlongsideTheOtherSettings() throws {
        let directory = try scratch()
        let url = Settings.fileURL(in: directory)
        try Settings(terminal: "ghostty", claudePath: "/custom/claude").save(to: url)
        let model = InboxModel(settingsURL: url, remindersURL: ReminderState.fileURL(in: directory))
        #expect(model.reminderSettings == ReminderSettings())

        model.updateReminders {
            $0.setSteps(first: 300, second: 3600)
            $0.repeatEvery = nil
            $0.quietHours = QuietHours(startMinute: 23 * 60, endMinute: 6 * 60)
        }
        let saved = Settings.load(from: url)
        #expect(saved.terminal == "ghostty" && saved.claudePath == "/custom/claude")
        #expect(saved.reminders?.ladder == [300, 3600])
        #expect(saved.reminders?.repeatEvery == nil)
        #expect(saved.reminders?.quietHours?.startMinute == 23 * 60)
        // A fresh model reads them back.
        #expect(InboxModel(settingsURL: url, remindersURL: ReminderState.fileURL(in: directory)).reminderSettings == model.reminderSettings)

        // "Waited long" follows the second step: an hour-old wait is overdue once that step is an hour.
        var snapshot = StoreSnapshot()
        snapshot.sessions = [Session(summary: SessionSummary(id: "a", name: "a", cwd: "/x/a", state: .blocked), observedBlockedSince: Date() - 5000)]
        model.apply(snapshot)
        #expect(model.status == .overdue(count: 1))
        model.updateReminders { $0.setSteps(first: 300, second: 4 * 3600) }
        #expect(model.status == .waiting(count: 1))

        // No change, no write.
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        model.updateReminders { _ in }
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func aChangedSettingAppliesAtTheNextRefreshWithoutARestart() async throws {
        let directory = try scratch()
        let settings = Box(ReminderSettings(digestMinute: nil))
        let delivery = CollectingDelivery()
        let fixed = now
        let engine = ReminderEngine(
            delivery: delivery, stateURL: ReminderState.fileURL(in: directory), settings: { settings.value }, now: { fixed })
        var snapshot = StoreSnapshot()
        snapshot.fetchedAt = now
        // Waiting for ten minutes: before the default first step of fifteen.
        snapshot.sessions = [Session(summary: SessionSummary(id: "a", name: "a", cwd: "/x/a", state: .blocked), observedBlockedSince: now - 600)]

        #expect(await engine.process(snapshot).isEmpty)
        var sooner = settings.value
        sooner.setSteps(first: 300, second: 3600)
        settings.value = sooner
        #expect(await engine.process(snapshot).map(\.id) == ["session-a"])
        #expect(await delivery.ids == ["session-a"])
    }

    @Test func theSettingsPageReplacesTheListAndShowsTheCurrentValues() throws {
        var actions = InboxActions()
        let inbox = try render(InboxView(snapshot: StoreSnapshot(), actions: actions, scrolls: false))
        actions.showsSettings = true
        actions.reminders.quietHours = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        let page = try render(InboxView(snapshot: StoreSnapshot(), actions: actions, scrolls: false), named: "settings")
        // Seven rows of settings: much taller than the empty inbox.
        #expect(page.pixelsHigh > inbox.pixelsHigh + 250)

        var toggled: [Bool] = []
        actions.setShowsSettings = { toggled.append($0) }
        actions.setShowsSettings(!actions.showsSettings)
        #expect(toggled == [false])
    }

    func render(_ view: some View, named name: String? = nil) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
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
