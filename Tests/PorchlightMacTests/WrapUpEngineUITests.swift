import AppKit
import Foundation
import SwiftUI
import Testing

@testable import PorchlightCore
@testable import PorchlightUI

@MainActor
@Suite struct WrapUpEngineUITests {
    let onThisMac = WrapUpPlan(chosen: .onDevice, model: "haiku", onDevice: .available)
    let withClaude = WrapUpPlan(chosen: .claude, model: "haiku", onDevice: .available)
    let notReady = WrapUpPlan(chosen: .onDevice, model: "haiku", onDevice: .notReady("System model unavailable"))

    @Test func theEngineInForceIsTheChoiceWhereThisMacCanHonourIt() {
        #expect(onThisMac.engine == .onDevice && withClaude.engine == .claude)
        #expect(notReady.engine == .claude && WrapUpPlan(chosen: .onDevice, onDevice: .missing).engine == .claude)
        // Before anything is known, nothing is assumed about this Mac.
        #expect(WrapUpPlan().engine == .claude)
    }

    @Test func theQuestionNamesTheEngineAndWhatItCosts() {
        let local = TriageRow.wrapUpQuestion(onThisMac)
        #expect(local.contains("on this Mac") && local.contains("free") && local.contains("nothing leaves this Mac") && local.contains("the end of the conversation"))
        #expect(!local.contains("Claude usage") && !local.contains("haiku"))
        #expect(TriageRow.claudeInstead(onThisMac) == "Read all of it with haiku (uses Claude usage)")

        let claude = TriageRow.wrapUpQuestion(withClaude)
        #expect(claude == TriageRow.wrapUpQuestion(model: "haiku") && claude.contains("Claude usage"))

        // The choice was this Mac and it cannot be honoured: why, how to fix it, then Claude's question.
        let fallback = TriageRow.wrapUpQuestion(notReady)
        #expect(fallback.hasPrefix("Apple's on-device model is not ready: System model unavailable"))
        #expect(fallback.contains("sudo fm license") && fallback.hasSuffix(TriageRow.wrapUpQuestion(model: "haiku")))
    }

    @Test func claudeUsageIsSpentOnlyByItsButtonOrTheSetting() async {
        let world = TriageWorld()
        world.plan = onThisMac
        let model = world.model
        await model.load()
        #expect(model.plan == onThisMac)

        model.askWrapUp("wait0005")
        await model.confirmWrapUp()
        #expect(world.wrapped == ["wait0005 on-device"])
        #expect(model.notes["wait0005"]?.model == "Apple's on-device model")

        // The row's third button: Claude for this one, and only this one.
        model.askWrapUp("wait0005")
        await model.confirmWrapUp(with: .claude)
        model.askWrapUp("safe0002")
        await model.confirmWrapUp()
        #expect(world.wrapped == ["wait0005 on-device", "wait0005 haiku", "safe0002 on-device"])

        // The setting changed to Claude: now the plain answer is Claude, and nothing can turn it
        // into the on-device model behind the question's back.
        world.plan = withClaude
        await model.refreshPlan()
        model.askWrapUp("safe0001")
        await model.confirmWrapUp(with: .onDevice)
        #expect(world.wrapped.last == "safe0001 haiku")

        // Not ready: Claude, which the question said.
        world.plan = notReady
        await model.refreshPlan()
        model.askWrapUp("safe0001")
        await model.confirmWrapUp()
        #expect(world.wrapped.last == "safe0001 haiku" && world.wrapped.count == 5)
    }

    @Test func theRowSaysWhichEngineIsWorking() async {
        let world = TriageWorld()
        world.plan = onThisMac
        world.holdsWrapUp = true
        let model = world.model
        await model.load()
        model.askWrapUp("wait0005")
        let running = Task { await model.confirmWrapUp() }
        while model.summarising == nil { await Task.yield() }
        #expect(model.summarisingEngine == .onDevice && TriageState(model).summarisingEngine == .onDevice)
        world.release()
        await running.value
        #expect(model.summarisingEngine == nil)
    }

    @Test func theSettingIsSavedAndReadBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("porchlight-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = Settings.fileURL(in: directory)
        try Data(#"{"wrapUp":{"model":"sonnet"},"preferAgentView":true}"#.utf8).write(to: url)
        let inbox = InboxModel(settingsURL: url, remindersURL: ReminderState.fileURL(in: directory))
        #expect(Settings.load(from: url).wrapUp?.engine == .onDevice)
        inbox.setWrapUpEngine(.claude)
        let saved = Settings.load(from: url)
        // The engine changed; the model and the other settings stayed.
        #expect(saved.wrapUp == WrapUpSettings(model: "sonnet", engine: .claude) && saved.preferAgentView == true)
        inbox.setWrapUpEngine(.onDevice)
        #expect(Settings.load(from: url).wrapUp == WrapUpSettings(model: "sonnet", engine: .onDevice))

        var calls: [WrapUpEngine] = []
        var actions = InboxActions()
        actions.setWrapUpEngine = { calls.append($0) }
        actions.confirmWrapUpWithClaude = { calls.append(.claude) }
        actions.setWrapUpEngine(.onDevice)
        actions.confirmWrapUpWithClaude()
        #expect(calls == [.onDevice, .claude])
    }

    @Test func theSettingsPageExplainsTheChoice() {
        #expect(SettingsPage.wrapUpNote(onThisMac).contains("free and nothing leaves this Mac"))
        #expect(SettingsPage.wrapUpNote(withClaude).contains("using haiku") && SettingsPage.wrapUpNote(withClaude).contains("Claude usage"))
        let blocked = SettingsPage.wrapUpNote(notReady)
        #expect(blocked.contains("sudo fm license") && blocked.contains("Until then Claude (haiku) is used"))
        #expect(SettingsPage.wrapUpNote(WrapUpPlan(chosen: .onDevice, onDevice: .missing)).contains("macOS 26"))
    }

    func height(_ actions: InboxActions, named name: String? = nil) throws -> CGFloat {
        let view = InboxView(snapshot: StoreSnapshot(), now: TriageWorld.now, actions: actions, scrolls: false)
        let renderer = ImageRenderer(content: view.background(Color.white).environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        if let name, let directory = ProcessInfo.processInfo.environment["PORCHLIGHT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let tiff = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: tiff))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent("\(name).png"))
        }
        return image.size.height
    }

    @Test func theQuestionAndTheSettingsAreDrawn() async throws {
        let world = TriageWorld()
        let model = world.model
        await model.load()
        model.askWrapUp("wait0005")
        var actions = InboxActions()
        actions.showsTriage = true
        actions.triageNow = TriageWorld.now
        actions.triage = TriageState(model)
        let claude = try height(actions)
        // On this Mac the question has a third button, for Claude.
        actions.triage.plan = onThisMac
        #expect(try height(actions, named: "triage-wrap-local") > claude + 15)

        var settings = InboxActions()
        settings.showsSettings = true
        settings.triage.plan = onThisMac
        let ready = try height(settings, named: "settings-wrap-up")
        // The note about what stands in the way is longer than the note about what it does.
        settings.triage.plan = notReady
        #expect(try height(settings, named: "settings-wrap-up-blocked") > ready)
        #expect(ready > 300)
    }
}
